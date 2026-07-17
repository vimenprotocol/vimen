// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IBasketHolders {
    function holderCount() external view returns (uint256);
    function holderAt(uint256 i) external view returns (address);
    function balanceOf(address a) external view returns (uint256);
}

/// @title BasketDistributor — pushes a basket's USDG income to its holders
/// @notice Every BasketToken2 sweeps its rebalance surplus here; on a fixed
///         interval anyone may run a payout cycle that pushes the pot
///         pro-rata to the basket's registered holders. Push, not claim: no
///         portal, no gas-wars, no unclaimed drift — the model proven by
///         $INDEX's StockDistributor on this chain, hardened in three ways:
///         - the SNAPSHOT is paginated too (theirs is O(holders) in one tx
///           and bricks past ~600 holders — a death sentence in an immutable
///           contract), deduped per cycle so registry churn between batches
///           can't double-pay: a wallet the churn hides loses one cycle at
///           worst, and its share simply rolls into the next pot;
///         - a payout transfer that reverts is SKIPPED, not fatal: one
///           frozen wallet cannot brick everyone's cycle; the skipped share
///           rolls forward;
///         - no owner: the interval is immutable and the only knob is the
///           exclusion list (infra addresses — pools, the basket itself —
///           whose share stays in the pot), held by the protocol Safe and
///           payout-only by construction: exclusion can never touch
///           principal, custody or redemption.
contract BasketDistributor is ReentrancyGuard {
    using {_push} for IERC20;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error BadInterval();
    error TooEarly();
    error NotIdle();
    error WrongPhase();
    error NothingToDistribute();
    error NotAdmin();
    error ZeroCount();

    // ---------------------------------------------------------------- events

    event CycleStarted(uint256 indexed cycleId, uint256 pot);
    event SnapshotBatch(uint256 indexed cycleId, uint256 through, uint256 eligible);
    event PaidBatch(uint256 indexed cycleId, uint256 from, uint256 to);
    event CycleFinished(uint256 indexed cycleId, uint256 paid, uint256 holders);
    event ExcludedSet(address indexed account, bool excluded);

    // ------------------------------------------------------------- constants

    uint256 public constant MIN_INTERVAL = 1 days;
    uint256 public constant MAX_INTERVAL = 90 days;

    // --------------------------------------------------------------- storage

    enum Phase {
        Idle,
        Snapshotting,
        Paying
    }

    IBasketHolders public immutable basket;
    IERC20 public immutable usdg;
    uint256 public immutable interval;
    /// @notice The protocol Safe; manages the (payout-only) exclusion list.
    address public immutable admin;

    mapping(address => bool) public excluded;

    Phase public phase;
    uint256 public cycleId;
    uint256 public nextDistribution;
    uint256 public cursor;
    uint256 public pot; // USDG snapshot the active cycle distributes
    uint256 public eligible; // Σ snapshot balances
    uint256 public paidOut; // USDG actually delivered this cycle

    address[] private _holders;
    uint256[] private _bals;
    mapping(uint256 cycleId => mapping(address holder => bool)) private _seen;

    // ----------------------------------------------------------- constructor

    constructor(IBasketHolders basket_, IERC20 usdg_, uint256 interval_, address admin_, address[] memory excluded_) {
        if (address(basket_) == address(0) || address(usdg_) == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        if (interval_ < MIN_INTERVAL || interval_ > MAX_INTERVAL) revert BadInterval();
        basket = basket_;
        usdg = usdg_;
        interval = interval_;
        admin = admin_;
        for (uint256 i = 0; i < excluded_.length; i++) {
            excluded[excluded_[i]] = true;
            emit ExcludedSet(excluded_[i], true);
        }
        // the basket contract itself never earns its own income
        excluded[address(basket_)] = true;
        emit ExcludedSet(address(basket_), true);
    }

    // ----------------------------------------------------------------- admin

    /// @notice Mark infra (a pool, a splitter) whose share stays in the pot.
    ///         Payout-only lever: principal, custody and redemption are out
    ///         of reach by construction. Takes effect from the next snapshot.
    function setExcluded(address account, bool excluded_) external {
        if (msg.sender != admin) revert NotAdmin();
        excluded[account] = excluded_;
        emit ExcludedSet(account, excluded_);
    }

    // ----------------------------------------------------------------- cycle

    /// @notice Open a payout cycle. Permissionless poke, at most one per
    ///         `interval`; the next window opens immediately so slow
    ///         pagination never delays the schedule.
    function startCycle() external nonReentrant {
        if (phase != Phase.Idle) revert NotIdle();
        if (block.timestamp < nextDistribution) revert TooEarly();
        uint256 balance = usdg.balanceOf(address(this));
        if (balance == 0) revert NothingToDistribute();

        nextDistribution = block.timestamp + interval;
        cycleId += 1;
        pot = balance;
        paidOut = 0;
        eligible = 0;
        cursor = 0;
        delete _holders;
        delete _bals;
        phase = Phase.Snapshotting;
        emit CycleStarted(cycleId, balance);
    }

    /// @notice Copy up to `count` registry entries into the cycle snapshot.
    ///         Permissionless poke; call until the phase advances. The
    ///         registry may churn between batches: the per-cycle dedupe
    ///         makes double-pay impossible, and at worst a churned wallet
    ///         misses this cycle (its share rolls into the next pot).
    function snapshotBatch(uint256 count) external nonReentrant {
        if (phase != Phase.Snapshotting) revert WrongPhase();
        if (count == 0) revert ZeroCount();

        uint256 n = basket.holderCount();
        uint256 end = cursor + count;
        if (end > n) end = n;
        uint256 elig = eligible;
        for (uint256 i = cursor; i < end; i++) {
            address holder = basket.holderAt(i);
            if (excluded[holder] || _seen[cycleId][holder]) continue;
            _seen[cycleId][holder] = true;
            uint256 balance = basket.balanceOf(holder);
            if (balance == 0) continue;
            _holders.push(holder);
            _bals.push(balance);
            elig += balance;
        }
        eligible = elig;
        cursor = end;
        emit SnapshotBatch(cycleId, end, elig);

        if (end >= basket.holderCount()) {
            cursor = 0;
            // nobody eligible: the pot simply waits for the next cycle
            phase = elig == 0 ? Phase.Idle : Phase.Paying;
            if (elig == 0) emit CycleFinished(cycleId, 0, 0);
        }
    }

    /// @notice Pay up to `count` snapshot holders their pro-rata share.
    ///         Permissionless poke; a reverting transfer (frozen wallet) is
    ///         skipped and its share rolls into the next pot.
    function distributeBatch(uint256 count) external nonReentrant {
        if (phase != Phase.Paying) revert WrongPhase();
        if (count == 0) revert ZeroCount();

        uint256 n = _holders.length;
        uint256 end = cursor + count;
        if (end > n) end = n;
        uint256 pot_ = pot;
        uint256 elig = eligible;
        uint256 delivered = paidOut;
        for (uint256 i = cursor; i < end; i++) {
            uint256 amount = (pot_ * _bals[i]) / elig; // dust rolls forward
            if (amount == 0) continue;
            if (usdg._push(_holders[i], amount)) delivered += amount;
        }
        paidOut = delivered;
        emit PaidBatch(cycleId, cursor, end);
        cursor = end;

        if (end == n) {
            phase = Phase.Idle;
            emit CycleFinished(cycleId, delivered, n);
        }
    }

    // ------------------------------------------------------------------ view

    /// @notice True when a new cycle can start right now.
    function canStart() external view returns (bool) {
        return phase == Phase.Idle && block.timestamp >= nextDistribution && usdg.balanceOf(address(this)) > 0;
    }

    /// @notice Registry entries still to snapshot / holders still to pay.
    function remaining() external view returns (uint256) {
        if (phase == Phase.Snapshotting) {
            uint256 n = basket.holderCount();
            return n > cursor ? n - cursor : 0;
        }
        if (phase == Phase.Paying) return _holders.length - cursor;
        return 0;
    }

    function snapshotSize() external view returns (uint256) {
        return _holders.length;
    }
}

/// @dev Non-reverting ERC20 push: returns success instead of bubbling, so
///      one frozen recipient can never brick a payout cycle. A token that
///      returns nothing (non-standard) counts as success when the call
///      succeeded.
function _push(IERC20 token, address to, uint256 amount) returns (bool) {
    (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
    return ok && (ret.length == 0 || abi.decode(ret, (bool)));
}
