// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FeeSplitter — routes basket mint fees 60/40
/// @notice The `feeRecipient` of every factory-created basket. Fees arrive as
///         basket tokens; anyone can call `distribute` to push 60% straight to
///         the basket's curator and 40% to the protocol treasury. Splits are
///         constants — no admin can change them. With the burn-for-license
///         model there is no staking pool: the curator's share is paid
///         directly to their wallet, in full.
contract FeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error AlreadyInitialized();
    error NotDeployer();
    error NotFactory();
    error UnknownBasket();

    event BasketRegistered(address indexed basket, address indexed curator);
    event Distributed(address indexed basket, address indexed curator, uint256 toCurator, uint256 toTreasury);

    uint256 public constant CURATOR_SHARE_BPS = 6_000; // 60%, forever

    address public immutable treasury;
    address private immutable deployer;
    address public factory; // set once at deployment wiring, then frozen

    mapping(address basket => address curator) public curatorOf;

    constructor(address treasury_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        deployer = msg.sender;
    }

    /// @notice One-shot deployment wiring; frozen forever afterwards.
    function initFactory(address factory_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (factory != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function register(address basket, address curator) external {
        if (msg.sender != factory) revert NotFactory();
        curatorOf[basket] = curator;
        emit BasketRegistered(basket, curator);
    }

    /// @notice Push accumulated fees of `basket` to their destinations.
    ///         Permissionless — the UI (or anyone) can trigger it.
    function distribute(address basket) external nonReentrant {
        address curator = curatorOf[basket];
        if (curator == address(0)) revert UnknownBasket();

        uint256 balance = IERC20(basket).balanceOf(address(this));
        if (balance == 0) return;

        uint256 toCurator = (balance * CURATOR_SHARE_BPS) / 10_000;
        uint256 toTreasury = balance - toCurator;

        if (toCurator > 0) IERC20(basket).safeTransfer(curator, toCurator);
        if (toTreasury > 0) IERC20(basket).safeTransfer(treasury, toTreasury);
        emit Distributed(basket, curator, toCurator, toTreasury);
    }
}
