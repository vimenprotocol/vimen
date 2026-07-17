// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {MakerRegistry} from "./MakerRegistry.sol";

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title BasketToken2 — the agentic basket: living recipe, unlocked exit
/// @notice V1's trust core, untouched: mint deposits the current backing
///         in-kind, redeem burns and returns it in-kind and is callable in
///         EVERY contract state — no pause, cap, guardian, curator or agent
///         power can ever gate it. What V2 adds is one mutation path,
///         `rebalance`, driven by an off-chain agent key but bounded by
///         policy this contract enforces on-chain:
///
///         - cooldown: at most one rebalance per `rebalanceCooldown`;
///         - universe: only AssetRegistry assets (feed-priced; buys need the
///           asset enabled, sells never do — exiting risk is always allowed);
///         - venues: only MakerRegistry settlement contracts, filled through
///           the audited RFQ boundary (approve exact -> call -> delta-check
///           -> approval reset);
///         - turnover: the value sold per rebalance is capped at
///           `maxTurnoverBps` of NAV;
///         - value: post-trade NAV (Chainlink-priced, staleness-checked)
///           plus anything swept to holders must cover pre-trade NAV minus
///           `maxSlippageBps` of NAV — the agent pays spreads, it cannot
///           leak value;
///         - supply: the shared reentrancy guard means a maker cannot
///           re-enter mint/redeem inside a rebalance transaction at all
///           (redeem stays ungated across transactions, as always), and a
///           supply snapshot check backs that up, so the invariant is
///           always measured on a fixed supply.
///
///         After every rebalance the units are recomputed from the actual
///         balances (floor), so full backing holds by construction. Any USDG
///         surplus a rebalance leaves behind is swept to the basket's
///         distributor and paid out to holders: residue belongs to holders,
///         not to the contract, not to the agent. A worst-case (compromised
///         or malicious) agent key can cost at most `maxSlippageBps` of NAV
///         per cooldown window (the invariant is measured on total NAV, not
///         on the traded notional) — and can never touch custody, block
///         redemption, or route value anywhere but the holders' distributor.
contract BasketToken2 is ERC20, ReentrancyGuard {
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
    error NotCurator();
    error NotAgent();
    error NotDeployer();
    error AlreadyInitialized();
    error CooldownActive();
    error ZeroSupply();
    error AssetNotRegistered(address token);
    error AssetNotBuyable(address token);
    error MakerNotRegistered(address maker);
    error NotAConstituent(address token);
    error ForbiddenToken(address token);
    error TurnoverExceeded(uint256 soldValue, uint256 maxValue);
    error LegUnderfilled(uint256 legIndex);
    error LegOversold(uint256 legIndex);
    error RemovedTokenHasBalance(address token);
    error NavInvariantBroken(uint256 navPre, uint256 navPost, uint256 swept);
    error SupplyChangedDuringRebalance();
    error StalePrice(address feed);
    error MakerCallFailed(uint256 legIndex);
    error PolicyOutOfBounds();

    // ---------------------------------------------------------------- events

    event Minted(address indexed sender, address indexed to, uint256 basketAmount, uint256 fee);
    event Redeemed(address indexed sender, address indexed to, uint256 basketAmount);
    event MintPausedSet(bool paused);
    event SupplyCapSet(uint256 newCap);
    event FeeRecipientSet(address indexed newRecipient);
    event AgentSet(address indexed newAgent);
    event DistributorInitialized(address indexed distributor);
    event Rebalanced(
        uint256 navPre18, uint256 navPost18, uint256 sweptUsdg, address[] tokens, uint256[] unitsPerBasket
    );

    // ------------------------------------------------------------- constants

    uint256 private constant ONE = 1e18;
    uint256 public constant MAX_FEE_BPS = 50;
    uint256 public constant MIN_CONSTITUENTS = 2;
    uint256 public constant MAX_CONSTITUENTS = 20;

    /// Factory-level policy ceilings: a curator picks the basket's policy at
    /// publish time, but never looser than these.
    uint32 public constant MIN_COOLDOWN = 1 days;
    uint16 public constant MAX_TURNOVER_BPS = 2_500; // 25% of NAV per rebalance
    uint16 public constant MAX_SLIPPAGE_BPS = 100; // 1% of NAV per rebalance

    // --------------------------------------------------------------- storage

    /// @notice Guardian: may pause minting, adjust the supply cap (up to
    ///         `maxSupplyCap`) and move the fee recipient. Nothing else —
    ///         and when wired to CuratorGuardian2, only the cap lever exists.
    address public immutable guardian;
    /// @notice The recipe's author. One power: rotating the agent key.
    address public immutable curator;
    /// @notice Mint fee in bps, fixed at deployment; fee taken in basket
    ///         tokens so the backing invariant stays exact.
    uint16 public immutable mintFeeBps;
    uint256 public immutable maxSupplyCap;

    AssetRegistry public immutable assetRegistry;
    MakerRegistry public immutable makerRegistry;
    /// @notice The RFQ cash leg every maker settles against (6 decimals).
    IERC20 public immutable usdg;
    /// @notice Chainlink USDG/USD, for pricing swept surplus in the NAV
    ///         invariant. Frozen at deploy like the registry feeds.
    IAggregatorV3 public immutable usdgFeed;
    uint32 public immutable usdgHeartbeat;

    // policy, frozen at deploy inside the constants' bounds
    uint32 public immutable rebalanceCooldown;
    uint16 public immutable maxTurnoverBps;
    uint16 public immutable maxSlippageBps;

    /// @notice Wallets at or above this balance are tracked for payouts.
    uint256 public immutable minShareBalance;

    address public agent;
    address public feeRecipient;
    uint256 public supplyCap;
    bool public mintPaused;
    uint64 public lastRebalance;

    /// @notice Where rebalance surplus goes: the basket's payout distributor.
    ///         One-shot wiring by the deployer (the factory), then frozen.
    address public distributor;
    address private immutable _deployer;

    address[] private _tokens;
    uint256[] private _units; // raw constituent wei per 1e18 basket wei

    // holder registry (read by the distributor); LP/infra filtering happens
    // in the distributor's snapshot, this list is intentionally dumb
    address[] private _holders;
    mapping(address => uint256) private _holderIdx; // 1-based; 0 = absent

    // ------------------------------------------------------------- structs

    /// One RFQ fill. Sells move a constituent out for USDG, buys move USDG
    /// out for an asset; `maker` must be registered and is the ONLY address
    /// approved, for exactly the input amount, for the duration of the call.
    struct TradeLeg {
        bool isBuy;
        /// the constituent sold, or the asset bought
        address token;
        /// sell: EXACT constituent amount sold. buy: MIN asset amount received.
        uint256 amount;
        /// sell: MIN USDG proceeds. buy: EXACT USDG budget approved.
        uint256 usdgAmount;
        address maker;
        bytes data;
    }

    struct Policy {
        uint32 rebalanceCooldown;
        uint16 maxTurnoverBps;
        uint16 maxSlippageBps;
        uint256 minShareBalance;
    }

    /// Everything the recipe and its owners are (grouped to fit the stack).
    struct Init {
        string name;
        string symbol;
        address[] tokens;
        uint256[] unitsPerBasket;
        uint16 mintFeeBps;
        address feeRecipient;
        address guardian;
        uint256 maxSupplyCap;
        uint256 initialSupplyCap;
        address curator;
        address agent;
    }

    /// The platform plumbing every V2 basket shares.
    struct Wiring {
        AssetRegistry assetRegistry;
        MakerRegistry makerRegistry;
        IERC20 usdg;
        IAggregatorV3 usdgFeed;
        uint32 usdgHeartbeat;
    }

    // ----------------------------------------------------------- constructor

    constructor(Init memory init_, Wiring memory wiring_, Policy memory policy_)
        ERC20(init_.name, init_.symbol)
    {
        uint256 n = init_.tokens.length;
        if (n != init_.unitsPerBasket.length) revert LengthMismatch();
        if (n < MIN_CONSTITUENTS || n > MAX_CONSTITUENTS) revert InvalidConstituentCount();
        if (init_.mintFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (
            init_.feeRecipient == address(0) || init_.guardian == address(0) || init_.curator == address(0)
                || init_.agent == address(0) || address(wiring_.assetRegistry) == address(0)
                || address(wiring_.makerRegistry) == address(0) || address(wiring_.usdg) == address(0)
                || address(wiring_.usdgFeed) == address(0)
        ) revert ZeroAddress();
        if (init_.maxSupplyCap == 0 || init_.initialSupplyCap == 0) revert ZeroSupplyCap();
        if (init_.initialSupplyCap > init_.maxSupplyCap) revert CapExceedsMax();
        if (
            policy_.rebalanceCooldown < MIN_COOLDOWN || policy_.maxTurnoverBps == 0
                || policy_.maxTurnoverBps > MAX_TURNOVER_BPS || policy_.maxSlippageBps > MAX_SLIPPAGE_BPS
                || wiring_.usdgHeartbeat == 0
        ) revert PolicyOutOfBounds();

        for (uint256 i = 0; i < n; i++) {
            address token = init_.tokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (token.code.length == 0) revert NotAContract(token);
            if (init_.unitsPerBasket[i] == 0) revert ZeroUnits();
            if (token == address(wiring_.usdg) || token == address(this)) revert ForbiddenToken(token);
            if (!wiring_.assetRegistry.isRegistered(token)) revert AssetNotRegistered(token);
            for (uint256 j = 0; j < i; j++) {
                if (init_.tokens[j] == token) revert DuplicateToken();
            }
        }

        _tokens = init_.tokens;
        _units = init_.unitsPerBasket;
        mintFeeBps = init_.mintFeeBps;
        feeRecipient = init_.feeRecipient;
        guardian = init_.guardian;
        maxSupplyCap = init_.maxSupplyCap;
        supplyCap = init_.initialSupplyCap;
        curator = init_.curator;
        agent = init_.agent;
        assetRegistry = wiring_.assetRegistry;
        makerRegistry = wiring_.makerRegistry;
        usdg = wiring_.usdg;
        usdgFeed = wiring_.usdgFeed;
        usdgHeartbeat = wiring_.usdgHeartbeat;
        rebalanceCooldown = policy_.rebalanceCooldown;
        maxTurnoverBps = policy_.maxTurnoverBps;
        maxSlippageBps = policy_.maxSlippageBps;
        minShareBalance = policy_.minShareBalance;
        lastRebalance = uint64(block.timestamp);
        _deployer = msg.sender;
    }

    // ------------------------------------------------------------- modifiers

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        _;
    }

    // ----------------------------------------------------------- mint/redeem
    // byte-for-byte V1 semantics: deposit the CURRENT units, redeem the
    // CURRENT units, redeem gated by nothing, ever.

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
            if (token.balanceOf(address(this)) - balanceBefore < required) {
                revert InsufficientDeposit(address(token));
            }
        }

        uint256 fee = (basketAmount * mintFeeBps) / 10_000;
        _mint(to, basketAmount - fee);
        if (fee > 0) _mint(feeRecipient, fee);

        emit Minted(msg.sender, to, basketAmount, fee);
    }

    /// @dev MUST be callable in every contract state: no pause, cap, cooldown
    ///      or role gates this function. (The shared reentrancy guard only
    ///      blocks calls nested INSIDE a rebalance transaction — across
    ///      transactions redeem is unconditional, always.)
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

    // ------------------------------------------------------------- rebalance

    /// @notice The single mutation path. Executes the legs through registered
    ///         makers, then re-derives the recipe from actual balances and
    ///         proves the policy held. To distribute income, the agent sells
    ///         without re-buying: every USDG surplus is swept to the
    ///         distributor for holders.
    /// @param legs   sells first is not required — sells and buys may
    ///               interleave; each leg is independently delta-checked.
    /// @param newTokens the constituent set after this rebalance (2..20).
    ///               Tokens dropped from the set must end at zero balance.
    function rebalance(TradeLeg[] calldata legs, address[] calldata newTokens) external onlyAgent nonReentrant {
        if (block.timestamp < lastRebalance + rebalanceCooldown) revert CooldownActive();
        uint256 supply = totalSupply();
        if (supply == 0) revert ZeroSupply();
        if (distributor == address(0)) revert ZeroAddress();

        uint256 usdgPre = usdg.balanceOf(address(this));
        uint256 navPre = _nav(_tokens) + _usdgValue18(usdgPre);

        // ---- execute legs through the RFQ boundary
        uint256 soldValue18;
        for (uint256 k = 0; k < legs.length; k++) {
            TradeLeg calldata leg = legs[k];
            if (!makerRegistry.isMaker(leg.maker)) revert MakerNotRegistered(leg.maker);
            if (leg.token == address(usdg) || leg.token == address(this)) revert ForbiddenToken(leg.token);
            if (leg.isBuy) {
                if (!assetRegistry.isBuyable(leg.token)) revert AssetNotBuyable(leg.token);
                _fillLeg(k, leg, usdg, IERC20(leg.token), leg.usdgAmount, leg.amount);
            } else {
                if (!_isConstituent(leg.token)) revert NotAConstituent(leg.token);
                soldValue18 += Math.mulDiv(leg.amount, _price8(leg.token), 1e8);
                _fillLeg(k, leg, IERC20(leg.token), usdg, leg.amount, leg.usdgAmount);
            }
        }
        uint256 maxSold = (navPre * maxTurnoverBps) / 10_000;
        if (soldValue18 > maxSold) revert TurnoverExceeded(soldValue18, maxSold);

        // ---- supply must not have moved. The reentrancy guard already
        //      blocks nested mint/redeem; this is defense-in-depth for the
        //      invariant's fixed base.
        if (totalSupply() != supply) revert SupplyChangedDuringRebalance();

        // ---- adopt the new recipe from actual balances
        _adoptRecipe(newTokens, supply);

        // ---- sweep surplus USDG to the holders' distributor
        uint256 usdgPost = usdg.balanceOf(address(this));
        uint256 swept = usdgPost > usdgPre ? usdgPost - usdgPre : 0;
        if (swept > 0) usdg.safeTransfer(distributor, swept);

        // ---- the value invariant: holders keep (new backing + sweep),
        //      which must cover the old backing minus the slippage budget
        uint256 navPost = _nav(_tokens) + _usdgValue18(usdgPost - swept);
        uint256 floor_ = navPre - (navPre * maxSlippageBps) / 10_000;
        if (navPost + _usdgValue18(swept) < floor_) revert NavInvariantBroken(navPre, navPost, swept);

        lastRebalance = uint64(block.timestamp);
        emit Rebalanced(navPre, navPost, swept, _tokens, _units);
    }

    /// @dev approve exact -> call maker -> delta-check both sides -> reset.
    ///      `inExact` is fully approved and must be fully taken (a partial
    ///      fill would strand approval-sized dust in pricing assumptions);
    ///      `outMin` is the leg's own floor on what comes back.
    function _fillLeg(
        uint256 k,
        TradeLeg calldata leg,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 inExact,
        uint256 outMin
    ) private {
        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = tokenOut.balanceOf(address(this));
        tokenIn.forceApprove(leg.maker, inExact);
        (bool ok,) = leg.maker.call(leg.data);
        if (!ok) revert MakerCallFailed(k);
        tokenIn.forceApprove(leg.maker, 0);
        uint256 spent = inBefore - tokenIn.balanceOf(address(this));
        if (spent > inExact) revert LegOversold(k); // unreachable via approval; belt-and-braces
        if (spent < inExact) revert LegUnderfilled(k);
        if (tokenOut.balanceOf(address(this)) - outBefore < outMin) revert LegUnderfilled(k);
    }

    /// @dev The new constituent set, derived from what the contract actually
    ///      holds: units = floor(balance / supply). Floor guarantees backing;
    ///      dropped tokens must be fully sold out (stranded residue would be
    ///      value no holder can ever redeem).
    function _adoptRecipe(address[] calldata newTokens, uint256 supply) private {
        uint256 n = newTokens.length;
        if (n < MIN_CONSTITUENTS || n > MAX_CONSTITUENTS) revert InvalidConstituentCount();

        for (uint256 i = 0; i < _tokens.length; i++) {
            address old = _tokens[i];
            bool kept = false;
            for (uint256 j = 0; j < n; j++) {
                if (newTokens[j] == old) {
                    kept = true;
                    break;
                }
            }
            if (!kept && IERC20(old).balanceOf(address(this)) != 0) revert RemovedTokenHasBalance(old);
        }

        uint256[] memory newUnits = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address token = newTokens[i];
            if (token == address(usdg) || token == address(this)) revert ForbiddenToken(token);
            if (!assetRegistry.isRegistered(token)) revert AssetNotRegistered(token);
            for (uint256 j = 0; j < i; j++) {
                if (newTokens[j] == token) revert DuplicateToken();
            }
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 u = Math.mulDiv(balance, ONE, supply);
            if (u == 0) revert ZeroUnits();
            newUnits[i] = u;
        }

        _tokens = newTokens;
        _units = newUnits;
    }

    // ------------------------------------------------------------ NAV & px

    function _isConstituent(address token) private view returns (bool) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == token) return true;
        }
        return false;
    }

    /// @dev Chainlink price (8 decimals) through the AssetRegistry's frozen
    ///      wiring; reverts on missing registration, non-positive answer or
    ///      staleness past the registered heartbeat (+1h grace).
    function _price8(address token) private view returns (uint256) {
        (address feed, uint32 heartbeat,) = assetRegistry.assetOf(token);
        return _read8(IAggregatorV3(feed), heartbeat);
    }

    function _read8(IAggregatorV3 feed, uint32 heartbeat) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || block.timestamp > updatedAt + heartbeat + 1 hours) revert StalePrice(address(feed));
        return uint256(answer);
    }

    /// @dev Σ balance × price over `tokens`, in 18-decimal USD. All
    ///      registered assets are 18-decimal tokens (AssetRegistry enforces).
    function _nav(address[] memory tokens) private view returns (uint256 nav18) {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) nav18 += Math.mulDiv(balance, _price8(tokens[i]), 1e8);
        }
    }

    /// @dev USDG (6 decimals) to 18-decimal USD via its own frozen feed.
    function _usdgValue18(uint256 amount6) private view returns (uint256) {
        if (amount6 == 0) return 0;
        return Math.mulDiv(amount6 * 1e12, _read8(usdgFeed, usdgHeartbeat), 1e8);
    }

    // ---------------------------------------------------------------- roles

    /// @notice Rotate the agent key. The curator's only power.
    function setAgent(address newAgent) external {
        if (msg.sender != curator) revert NotCurator();
        if (newAgent == address(0)) revert ZeroAddress();
        agent = newAgent;
        emit AgentSet(newAgent);
    }

    /// @notice One-shot wiring of the payout distributor by the deployer
    ///         (the factory), then frozen forever.
    function initDistributor(address distributor_) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (distributor != address(0)) revert AlreadyInitialized();
        if (distributor_ == address(0)) revert ZeroAddress();
        distributor = distributor_;
        emit DistributorInitialized(distributor_);
    }

    // --------------------------------------------------------- guardian-only

    function setMintPaused(bool paused) external onlyGuardian {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    function setSupplyCap(uint256 newCap) external onlyGuardian {
        if (newCap > maxSupplyCap) revert CapExceedsMax();
        supplyCap = newCap;
        emit SupplyCapSet(newCap);
    }

    function setFeeRecipient(address newRecipient) external onlyGuardian {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientSet(newRecipient);
    }

    // ------------------------------------------------------ holder registry
    // Tracks every wallet at/above minShareBalance; the distributor's
    // snapshot applies infra exclusions (pools, the basket, itself).

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return _holders[i];
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0)) _refreshHolder(from);
        if (to != address(0)) _refreshHolder(to);
    }

    function _refreshHolder(address a) private {
        uint256 idx = _holderIdx[a];
        if (balanceOf(a) >= minShareBalance) {
            if (idx == 0) {
                _holders.push(a);
                _holderIdx[a] = _holders.length;
            }
        } else if (idx != 0) {
            address last = _holders[_holders.length - 1];
            _holders[idx - 1] = last;
            _holderIdx[last] = idx;
            _holders.pop();
            _holderIdx[a] = 0;
        }
    }

    // ------------------------------------------------------------------ view

    function constituents() external view returns (address[] memory) {
        return _tokens;
    }

    function units() external view returns (uint256[] memory) {
        return _units;
    }

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

    function backingOf(uint256 basketAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = Math.mulDiv(basketAmount, _units[i], ONE);
        }
    }

    function isFullyBacked() external view returns (bool) {
        uint256 supply = totalSupply();
        uint256 n = _tokens.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 required = Math.mulDiv(supply, _units[i], ONE, Math.Rounding.Ceil);
            if (IERC20(_tokens[i]).balanceOf(address(this)) < required) return false;
        }
        return true;
    }

    /// @notice Live NAV per the registry's feeds, 18-decimal USD. Monitoring
    ///         convenience; nothing on-chain depends on it between rebalances.
    function nav18() external view returns (uint256) {
        return _nav(_tokens) + _usdgValue18(usdg.balanceOf(address(this)));
    }
}
