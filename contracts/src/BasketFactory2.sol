// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken2, IAggregatorV3} from "./BasketToken2.sol";
import {BasketTokenDeployer} from "./BasketTokenDeployer.sol";
import {BasketDistributor, IBasketHolders} from "./BasketDistributor.sol";
import {CuratorRegistry2} from "./CuratorRegistry2.sol";
import {CuratorGuardian} from "./CuratorGuardian.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {MakerRegistry} from "./MakerRegistry.sol";
import {FeeSplitter} from "./FeeSplitter.sol";

/// @title BasketFactory2 — publish an agentic basket
/// @notice The V2 shelf's factory: any V2-licensed curator (25k VIM burned,
///         or a grandfathered legacy license) deploys a BasketToken2 plus
///         its BasketDistributor, wired the same trust-minimized way as V1:
///         - feeRecipient = the FeeSplitter (60/40, constants);
///         - guardian    = the SAME CuratorGuardian instance guarding V1
///           curated baskets — its only lever is raising the supply cap, and
///           BasketToken2 exposes the identical cap interface;
///         - distributor admin = the protocol Safe (payout-exclusion list
///           only), read from the guardian so it can never diverge.
///         The curator picks the recipe, the agent key, the policy (inside
///         BasketToken2's hard ceilings) and the payout interval; after
///         publication the factory holds no power over the basket.
contract BasketFactory2 {
    error NotLicensed();
    error CapAboveFactoryLimit();
    error ZeroAddress();
    error MinShareOutOfBounds();

    event BasketCreated(
        address indexed basket,
        address indexed distributor,
        address indexed curator,
        string name,
        string symbol,
        uint256 initialSupplyCap
    );

    /// Every new basket starts capped; the guardian raises it on the roadmap.
    uint256 public constant STARTER_CAP = 1_000e18;
    uint256 public constant CEILING = 1_000_000e18;
    /// Payout-registry threshold bounds: low enough to include real holders,
    /// high enough that dust wallets can't bloat snapshot gas.
    uint256 public constant MIN_SHARE_FLOOR = 1e16; // 0.01 baskets
    uint256 public constant MIN_SHARE_CEILING = 100e18;

    CuratorRegistry2 public immutable registry;
    FeeSplitter public immutable splitter;
    CuratorGuardian public immutable basketGuardian;
    /// carries BasketToken2's creation code (EIP-170: it no longer fits here)
    BasketTokenDeployer public immutable tokenDeployer;
    AssetRegistry public immutable assetRegistry;
    MakerRegistry public immutable makerRegistry;
    IERC20 public immutable usdg;
    IAggregatorV3 public immutable usdgFeed;
    uint32 public immutable usdgHeartbeat;

    address[] private _baskets;
    mapping(address basket => address curator) public curatorOf;
    mapping(address basket => address) public distributorOf;

    constructor(
        CuratorRegistry2 registry_,
        FeeSplitter splitter_,
        CuratorGuardian basketGuardian_,
        AssetRegistry assetRegistry_,
        MakerRegistry makerRegistry_,
        IERC20 usdg_,
        IAggregatorV3 usdgFeed_,
        uint32 usdgHeartbeat_,
        BasketTokenDeployer tokenDeployer_
    ) {
        if (
            address(registry_) == address(0) || address(splitter_) == address(0)
                || address(basketGuardian_) == address(0) || address(assetRegistry_) == address(0)
                || address(makerRegistry_) == address(0) || address(usdg_) == address(0)
                || address(usdgFeed_) == address(0) || address(tokenDeployer_) == address(0)
        ) revert ZeroAddress();
        tokenDeployer = tokenDeployer_;
        registry = registry_;
        splitter = splitter_;
        basketGuardian = basketGuardian_;
        assetRegistry = assetRegistry_;
        makerRegistry = makerRegistry_;
        usdg = usdg_;
        usdgFeed = usdgFeed_;
        usdgHeartbeat = usdgHeartbeat_;
    }

    /// @notice Publish an agentic basket. Requires the V2 curation license.
    /// @param agent  the rebalancer key (rotatable later, by the curator only)
    /// @param policy cooldown/turnover/slippage/minShare — validated against
    ///               BasketToken2's immutable ceilings in its constructor
    /// @param payoutInterval seconds between distributor cycles (1..90 days)
    function createBasket(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata unitsPerBasket,
        uint16 mintFeeBps,
        uint256 initialSupplyCap,
        address agent,
        BasketToken2.Policy calldata policy,
        uint256 payoutInterval
    ) external returns (address basket, address distributor) {
        if (!registry.isLicensedV2(msg.sender)) revert NotLicensed();
        if (initialSupplyCap > STARTER_CAP) revert CapAboveFactoryLimit();
        if (policy.minShareBalance < MIN_SHARE_FLOOR || policy.minShareBalance > MIN_SHARE_CEILING) {
            revert MinShareOutOfBounds();
        }

        BasketToken2 token = tokenDeployer.deploy(
            BasketToken2.Init({
                name: name,
                symbol: symbol,
                tokens: tokens,
                unitsPerBasket: unitsPerBasket,
                mintFeeBps: mintFeeBps,
                feeRecipient: address(splitter),
                guardian: address(basketGuardian),
                maxSupplyCap: CEILING,
                initialSupplyCap: initialSupplyCap,
                curator: msg.sender,
                agent: agent
            }),
            BasketToken2.Wiring({
                assetRegistry: assetRegistry,
                makerRegistry: makerRegistry,
                usdg: usdg,
                usdgFeed: usdgFeed,
                usdgHeartbeat: usdgHeartbeat
            }),
            policy
        );

        // the splitter holds fee-minted basket tokens: exclude it from
        // payouts so fees don't recursively earn holder income
        address[] memory excluded = new address[](1);
        excluded[0] = address(splitter);
        BasketDistributor dist = new BasketDistributor(
            IBasketHolders(address(token)), usdg, payoutInterval, basketGuardian.admin(), excluded
        );
        // the token records the deployer helper as its `_deployer`, so the
        // one-shot wiring is forwarded through it (atomic within this tx)
        tokenDeployer.initDistributor(token, address(dist));
        splitter.register(address(token), msg.sender);

        basket = address(token);
        distributor = address(dist);
        curatorOf[basket] = msg.sender;
        distributorOf[basket] = distributor;
        _baskets.push(basket);
        emit BasketCreated(basket, distributor, msg.sender, name, symbol, initialSupplyCap);
    }

    function allBaskets() external view returns (address[] memory) {
        return _baskets;
    }

    function basketCount() external view returns (uint256) {
        return _baskets.length;
    }
}
