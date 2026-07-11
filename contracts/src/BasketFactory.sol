// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BasketToken} from "./BasketToken.sol";
import {CuratorRegistry} from "./CuratorRegistry.sol";
import {FeeSplitter} from "./FeeSplitter.sol";

/// @title BasketFactory — anyone can publish an index
/// @notice The factory of the curation platform: any address whose VIMEN
///         self-stake meets the license threshold can deploy a basket. The
///         factory wires every basket the same trust-minimized way:
///         - feeRecipient = the FeeSplitter (60% curator pool / 40% treasury,
///           constants — the curator can never redirect fees);
///         - guardian    = the protocol guardian Safe (cap roadmap applies
///           to curated baskets exactly like first-party ones).
///         Baskets themselves stay immutable BasketToken instances — the
///         factory adds no power over them after deployment.
contract BasketFactory {
    error NotLicensed();
    error CapAboveFactoryLimit();
    error ZeroAddress();

    event BasketCreated(
        address indexed basket, address indexed curator, string name, string symbol, uint256 initialSupplyCap
    );

    /// Every new basket starts capped (phase policy; the guardian raises it
    /// along the public roadmap).
    uint256 public constant STARTER_CAP = 1_000e18;
    uint256 public constant CEILING = 1_000_000e18;

    CuratorRegistry public immutable registry;
    FeeSplitter public immutable splitter;
    address public immutable protocolGuardian;

    address[] private _baskets;
    mapping(address basket => address curator) public curatorOf;

    constructor(CuratorRegistry registry_, FeeSplitter splitter_, address protocolGuardian_) {
        if (address(registry_) == address(0) || address(splitter_) == address(0) || protocolGuardian_ == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        splitter = splitter_;
        protocolGuardian = protocolGuardian_;
    }

    /// @notice Publish a basket. Requires an active curation license
    ///         (VIMEN self-stake >= registry.MIN_SELF_STAKE()).
    function createBasket(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata unitsPerBasket,
        uint16 mintFeeBps,
        uint256 initialSupplyCap
    ) external returns (address basket) {
        if (!registry.isLicensed(msg.sender)) revert NotLicensed();
        if (initialSupplyCap > STARTER_CAP) revert CapAboveFactoryLimit();

        basket = address(
            new BasketToken(
                name,
                symbol,
                tokens,
                unitsPerBasket,
                mintFeeBps,
                address(splitter),
                protocolGuardian,
                CEILING,
                initialSupplyCap
            )
        );
        splitter.register(basket, msg.sender);
        curatorOf[basket] = msg.sender;
        _baskets.push(basket);
        emit BasketCreated(basket, msg.sender, name, symbol, initialSupplyCap);
    }

    function allBaskets() external view returns (address[] memory) {
        return _baskets;
    }

    function basketCount() external view returns (uint256) {
        return _baskets.length;
    }
}
