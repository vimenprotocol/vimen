// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BasketToken — fully-backed, in-kind mint/redeem index token
/// @notice An ERC-20 backed 1:1 by fixed raw quantities of constituent ERC-20s
///         held by this contract. Mint deposits constituents in-kind; redeem
///         burns and returns constituents in-kind. No oracles, no rebalancing,
///         no upgradability, no admin control over funds.
/// @dev    Works purely on raw ERC-20 amounts. Constituents implementing the
///         ERC-8056 Scaled UI Amount extension are supported by construction:
///         the UI multiplier is never read here (display concern only).
///
///         Trust guarantee: `redeem` is callable in every contract state. No
///         pause, cap, or guardian power can ever block it. The only way a
///         redeem can fail is if a constituent token itself reverts the
///         transfer (e.g. an issuer-level freeze) — a risk this contract
///         inherits and cannot remove.
contract BasketToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error LengthMismatch();
    error InvalidConstituentCount();
    error DuplicateToken();
    error ZeroAddress();
    error NotAContract(address token);
    error ZeroUnits();
    error FeeTooHigh();
    error ZeroSupplyCap();
    error CapExceedsMax();
    error ZeroAmount();
    error MintingPaused();
    error SupplyCapExceeded();
    error InsufficientDeposit(address token);
    error NotGuardian();

    // ---------------------------------------------------------------- events

    event Minted(address indexed sender, address indexed to, uint256 basketAmount, uint256 fee);
    event Redeemed(address indexed sender, address indexed to, uint256 basketAmount);
    event MintPausedSet(bool paused);
    event SupplyCapSet(uint256 newCap);
    event FeeRecipientSet(address indexed newRecipient);

    // --------------------------------------------------------------- storage

    uint256 private constant ONE = 1e18;
    uint256 public constant MAX_FEE_BPS = 50;
    uint256 public constant MIN_CONSTITUENTS = 2;
    uint256 public constant MAX_CONSTITUENTS = 20;

    /// @notice Guardian: may pause minting, adjust the supply cap (up to
    ///         `maxSupplyCap`) and move the fee recipient. Nothing else.
    address public immutable guardian;
    /// @notice Mint fee in basis points, fixed at deployment. Fee is taken in
    ///         basket tokens, so the backing invariant stays exact.
    uint16 public immutable mintFeeBps;
    /// @notice Immutable ceiling for `supplyCap`; the guardian can never raise
    ///         the cap above this.
    uint256 public immutable maxSupplyCap;

    address public feeRecipient;
    uint256 public supplyCap;
    bool public mintPaused;

    address[] private _tokens;
    uint256[] private _units; // raw constituent wei per 1e18 basket wei

    // ----------------------------------------------------------- constructor

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory tokens_,
        uint256[] memory unitsPerBasket_,
        uint16 mintFeeBps_,
        address feeRecipient_,
        address guardian_,
        uint256 maxSupplyCap_,
        uint256 initialSupplyCap_
    ) ERC20(name_, symbol_) {
        uint256 n = tokens_.length;
        if (n != unitsPerBasket_.length) revert LengthMismatch();
        if (n < MIN_CONSTITUENTS || n > MAX_CONSTITUENTS) revert InvalidConstituentCount();
        if (mintFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (feeRecipient_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (maxSupplyCap_ == 0 || initialSupplyCap_ == 0) revert ZeroSupplyCap();
        if (initialSupplyCap_ > maxSupplyCap_) revert CapExceedsMax();

        for (uint256 i = 0; i < n; i++) {
            address token = tokens_[i];
            if (token == address(0)) revert ZeroAddress();
            if (token.code.length == 0) revert NotAContract(token);
            if (unitsPerBasket_[i] == 0) revert ZeroUnits();
            for (uint256 j = 0; j < i; j++) {
                if (tokens_[j] == token) revert DuplicateToken();
            }
        }

        _tokens = tokens_;
        _units = unitsPerBasket_;
        mintFeeBps = mintFeeBps_;
        feeRecipient = feeRecipient_;
        guardian = guardian_;
        maxSupplyCap = maxSupplyCap_;
        supplyCap = initialSupplyCap_;
    }

    // ------------------------------------------------------------- modifiers

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    // ----------------------------------------------------------- mint/redeem

    /// @notice Mint `basketAmount` basket tokens by depositing the required
    ///         raw amount of every constituent (see `getRequiredUnits`).
    ///         Caller must have approved this contract for each constituent.
    /// @param basketAmount Gross amount minted; `to` receives it net of fee.
    /// @param to Recipient of the minted basket tokens.
    function mint(uint256 basketAmount, address to) external nonReentrant {
        if (basketAmount == 0) revert ZeroAmount();
        if (mintPaused) revert MintingPaused();
        if (totalSupply() + basketAmount > supplyCap) revert SupplyCapExceeded();

        uint256 n = _tokens.length;
        for (uint256 i = 0; i < n; i++) {
            IERC20 token = IERC20(_tokens[i]);
            uint256 required = Math.mulDiv(basketAmount, _units[i], ONE, Math.Rounding.Ceil);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), required);
            // Balance-delta check: guards against fee-on-transfer, deflationary
            // or otherwise non-standard constituents under-delivering.
            if (token.balanceOf(address(this)) - balanceBefore < required) {
                revert InsufficientDeposit(address(token));
            }
        }

        uint256 fee = (basketAmount * mintFeeBps) / 10_000;
        _mint(to, basketAmount - fee);
        if (fee > 0) _mint(feeRecipient, fee);

        emit Minted(msg.sender, to, basketAmount, fee);
    }

    /// @notice Burn `basketAmount` basket tokens from the caller and transfer
    ///         the backing constituents (rounded down) to `to`.
    /// @dev    MUST be callable in every contract state: no pause, cap or
    ///         guardian power gates this function.
    function redeem(uint256 basketAmount, address to) external nonReentrant {
        if (basketAmount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        _burn(msg.sender, basketAmount);

        uint256 n = _tokens.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = Math.mulDiv(basketAmount, _units[i], ONE);
            IERC20(_tokens[i]).safeTransfer(to, amount);
        }

        emit Redeemed(msg.sender, to, basketAmount);
    }

    // --------------------------------------------------------- guardian-only

    /// @notice Pause or unpause minting. Never affects redeem.
    function setMintPaused(bool paused) external onlyGuardian {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    /// @notice Set the supply cap, up to the immutable `maxSupplyCap`.
    function setSupplyCap(uint256 newCap) external onlyGuardian {
        if (newCap > maxSupplyCap) revert CapExceedsMax();
        supplyCap = newCap;
        emit SupplyCapSet(newCap);
    }

    /// @notice Redirect future mint fees.
    function setFeeRecipient(address newRecipient) external onlyGuardian {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientSet(newRecipient);
    }

    // ------------------------------------------------------------------ view

    /// @notice Constituent token addresses.
    function constituents() external view returns (address[] memory) {
        return _tokens;
    }

    /// @notice Raw constituent wei per 1e18 basket wei, aligned with `constituents()`.
    function units() external view returns (uint256[] memory) {
        return _units;
    }

    /// @notice Exact raw deposits required to mint `basketAmount` (rounded up).
    function getRequiredUnits(uint256 basketAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = Math.mulDiv(basketAmount, _units[i], ONE, Math.Rounding.Ceil);
        }
    }

    /// @notice Raw constituent amounts returned when redeeming `basketAmount`
    ///         (rounded down).
    function backingOf(uint256 basketAmount) external view returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = Math.mulDiv(basketAmount, _units[i], ONE);
        }
    }

    /// @notice True when every constituent balance covers the total supply.
    ///         Should always hold; exposed for monitoring.
    function isFullyBacked() external view returns (bool) {
        uint256 supply = totalSupply();
        uint256 n = _tokens.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 required = Math.mulDiv(supply, _units[i], ONE, Math.Rounding.Ceil);
            if (IERC20(_tokens[i]).balanceOf(address(this)) < required) return false;
        }
        return true;
    }
}
