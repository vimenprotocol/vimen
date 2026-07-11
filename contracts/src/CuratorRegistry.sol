// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CuratorRegistry — VIMEN staking: the curation license
/// @notice One pool per curator. The curator's own stake is their license to
///         publish baskets (>= MIN_SELF_STAKE); anyone else can delegate
///         stake to a curator to share their fee income. Total pool stake is
///         the curator's shelf ranking (read by the frontend).
///
///         Fee flow: FeeSplitter transfers basket-token fees here and calls
///         `notifyReward`. The curator takes their commission off the top;
///         the rest accrues pro-rata to all stakers in the pool (the curator
///         earns on their own stake too). MultiRewards-style accounting, one
///         reward token per basket the curator has published.
///
///         No admin, no upgradability. The only privileged link — the
///         FeeSplitter address — is set once at deployment and frozen.
contract CuratorRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyInitialized();
    error NotDeployer();
    error NotSplitter();
    error CommissionTooHigh();
    error NotCurator();
    error InsufficientStake();
    error NonStandardToken();
    error NothingToWithdraw();
    error CooldownActive();
    error TooManyRewardTokens();

    // ---------------------------------------------------------------- events

    event Staked(address indexed curator, address indexed staker, uint256 amount);
    event UnstakeRequested(address indexed curator, address indexed staker, uint256 amount, uint256 releaseAt);
    event Withdrawn(address indexed staker, uint256 amount);
    /// @notice A commission change was announced; it becomes effective at
    ///         `effectiveAt`. Indexers should treat this as the source of
    ///         truth: `CommissionSet` is only emitted when the change is
    ///         later folded into storage, not at the moment it activates.
    event CommissionAnnounced(address indexed curator, uint16 bps, uint256 effectiveAt);
    event CommissionSet(address indexed curator, uint16 bps);
    event RewardNotified(address indexed curator, address indexed token, uint256 amount, uint256 commission);
    event Claimed(address indexed curator, address indexed staker, address indexed token, uint256 amount);

    // ------------------------------------------------------------- constants

    uint256 public constant MIN_SELF_STAKE = 25_000e18; // license threshold
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;
    // Aligned with UNSTAKE_COOLDOWN: a delegator who exits the moment a
    // change is announced is out before it takes effect.
    uint256 public constant COMMISSION_TIMELOCK = 7 days;
    uint16 public constant DEFAULT_COMMISSION_BPS = 2_000; // 20% of pool fees
    uint16 public constant MAX_COMMISSION_BPS = 5_000;
    uint256 public constant MAX_REWARD_TOKENS = 64;
    uint256 private constant ACC = 1e18;

    // --------------------------------------------------------------- storage

    IERC20 public immutable vimen;
    address private immutable deployer;
    address public splitter; // set once post-deploy (deployment wiring), then frozen

    // pool accounting
    mapping(address curator => uint256) public totalStake;
    mapping(address curator => mapping(address staker => uint256)) public stakeOf;

    // commission
    struct PendingCommission {
        uint16 bps;
        uint64 effectiveAt; // 0 = nothing announced
    }

    mapping(address curator => uint16) private _commission;
    mapping(address curator => bool) private _commissionSet;
    mapping(address curator => PendingCommission) public pendingCommission;

    // rewards (MultiRewards-style, per curator pool / per reward token)
    mapping(address curator => address[]) private _rewardTokens;
    mapping(address curator => mapping(address token => bool)) public isRewardToken;
    mapping(address curator => mapping(address token => uint256)) public accPerShare;
    mapping(address curator => mapping(address token => mapping(address staker => uint256))) public paidPerShare;
    mapping(address curator => mapping(address token => mapping(address staker => uint256))) public accrued;

    // unstake cooldown
    struct PendingWithdrawal {
        uint256 amount;
        uint256 releaseAt;
    }
    mapping(address staker => PendingWithdrawal) public pendingWithdrawal;

    // ----------------------------------------------------------- constructor

    constructor(IERC20 vimen_) {
        if (address(vimen_) == address(0)) revert ZeroAddress();
        vimen = vimen_;
        deployer = msg.sender;
    }

    /// @notice One-shot deployment wiring; frozen forever afterwards.
    function initSplitter(address splitter_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (splitter != address(0)) revert AlreadyInitialized();
        if (splitter_ == address(0)) revert ZeroAddress();
        splitter = splitter_;
    }

    // ------------------------------------------------------------ staking

    /// @notice Stake VIMEN into `curator`'s pool. Stake to your own address
    ///         to build your curation license.
    function stake(address curator, uint256 amount) external nonReentrant {
        if (curator == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _settle(curator, msg.sender);
        // The VIMEN contract is external to this protocol: reject any
        // fee-on-transfer / rebasing behavior outright, otherwise stake
        // accounting drifts from the actual balance.
        uint256 balanceBefore = vimen.balanceOf(address(this));
        vimen.safeTransferFrom(msg.sender, address(this), amount);
        if (vimen.balanceOf(address(this)) - balanceBefore != amount) revert NonStandardToken();
        stakeOf[curator][msg.sender] += amount;
        totalStake[curator] += amount;
        emit Staked(curator, msg.sender, amount);
    }

    /// @notice Start the exit: stake stops earning and ranking immediately,
    ///         tokens release after the cooldown. Repeated requests merge and
    ///         reset the clock.
    function requestUnstake(address curator, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakeOf[curator][msg.sender] < amount) revert InsufficientStake();
        _settle(curator, msg.sender);
        stakeOf[curator][msg.sender] -= amount;
        totalStake[curator] -= amount;
        PendingWithdrawal storage w = pendingWithdrawal[msg.sender];
        w.amount += amount;
        w.releaseAt = block.timestamp + UNSTAKE_COOLDOWN;
        emit UnstakeRequested(curator, msg.sender, amount, w.releaseAt);
    }

    function withdraw() external nonReentrant {
        PendingWithdrawal storage w = pendingWithdrawal[msg.sender];
        if (w.amount == 0) revert NothingToWithdraw();
        if (block.timestamp < w.releaseAt) revert CooldownActive();
        uint256 amount = w.amount;
        w.amount = 0;
        vimen.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------ curation

    /// @notice Announce a new commission on pool fee income (defaults to
    ///         20%). It takes effect after COMMISSION_TIMELOCK, so delegators
    ///         always get the full unstake cooldown as notice. Announcing
    ///         again replaces the pending change and restarts the clock.
    function setCommission(uint16 bps) external {
        if (bps > MAX_COMMISSION_BPS) revert CommissionTooHigh();
        _finalizeCommission(msg.sender);
        uint256 effectiveAt = block.timestamp + COMMISSION_TIMELOCK;
        pendingCommission[msg.sender] = PendingCommission({bps: bps, effectiveAt: uint64(effectiveAt)});
        emit CommissionAnnounced(msg.sender, bps, effectiveAt);
    }

    function commissionBps(address curator) public view returns (uint16) {
        PendingCommission storage pending = pendingCommission[curator];
        if (pending.effectiveAt != 0 && block.timestamp >= pending.effectiveAt) {
            return pending.bps;
        }
        return _commissionSet[curator] ? _commission[curator] : DEFAULT_COMMISSION_BPS;
    }

    /// @dev Fold a matured announcement into storage. Correctness never
    ///      depends on this running — `commissionBps` already reflects a
    ///      matured announcement — it only keeps a replaced announcement from
    ///      erasing one that has already activated.
    function _finalizeCommission(address curator) internal {
        PendingCommission storage pending = pendingCommission[curator];
        if (pending.effectiveAt != 0 && block.timestamp >= pending.effectiveAt) {
            _commission[curator] = pending.bps;
            _commissionSet[curator] = true;
            emit CommissionSet(curator, pending.bps);
            delete pendingCommission[curator];
        }
    }

    /// @notice The curation license: enough self-stake to publish baskets.
    function isLicensed(address curator) external view returns (bool) {
        return stakeOf[curator][curator] >= MIN_SELF_STAKE;
    }

    /// @notice Shelf ranking input: the pool's total stake.
    function effectiveStake(address curator) external view returns (uint256) {
        return totalStake[curator];
    }

    // ------------------------------------------------------------- rewards

    /// @notice Called by the FeeSplitter after transferring `amount` of
    ///         `token` (a basket token) to this contract. Commission goes to
    ///         the curator; the rest accrues pro-rata to the pool.
    function notifyReward(address curator, address token, uint256 amount) external {
        if (msg.sender != splitter) revert NotSplitter();
        if (amount == 0) return;

        if (!isRewardToken[curator][token]) {
            if (_rewardTokens[curator].length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
            isRewardToken[curator][token] = true;
            _rewardTokens[curator].push(token);
        }

        uint256 pool = totalStake[curator];
        uint256 commission = (amount * commissionBps(curator)) / 10_000;
        if (pool == 0) commission = amount; // nobody staked: all to the curator
        accrued[curator][token][curator] += commission;
        uint256 net = amount - commission;
        if (net > 0) {
            accPerShare[curator][token] += (net * ACC) / pool;
        }
        emit RewardNotified(curator, token, amount, commission);
    }

    /// @notice Claim all pending fee income from `curator`'s pool.
    function claim(address curator) external nonReentrant {
        _settle(curator, msg.sender);
        address[] storage tokens = _rewardTokens[curator];
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = accrued[curator][token][msg.sender];
            if (amount == 0) continue;
            accrued[curator][token][msg.sender] = 0;
            IERC20(token).safeTransfer(msg.sender, amount);
            emit Claimed(curator, msg.sender, token, amount);
        }
    }

    /// @notice Pending fee income of `staker` in `curator`'s pool.
    function pendingRewards(address curator, address staker)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _rewardTokens[curator];
        amounts = new uint256[](tokens.length);
        uint256 stakeAmount = stakeOf[curator][staker];
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 delta = accPerShare[curator][token] - paidPerShare[curator][token][staker];
            amounts[i] = accrued[curator][token][staker] + (stakeAmount * delta) / ACC;
        }
    }

    function rewardTokens(address curator) external view returns (address[] memory) {
        return _rewardTokens[curator];
    }

    /// @dev Realize a staker's pro-rata rewards before their stake changes.
    function _settle(address curator, address staker) internal {
        uint256 stakeAmount = stakeOf[curator][staker];
        address[] storage tokens = _rewardTokens[curator];
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 acc = accPerShare[curator][token];
            uint256 delta = acc - paidPerShare[curator][token][staker];
            if (delta > 0 && stakeAmount > 0) {
                accrued[curator][token][staker] += (stakeAmount * delta) / ACC;
            }
            paidPerShare[curator][token][staker] = acc;
        }
    }
}
