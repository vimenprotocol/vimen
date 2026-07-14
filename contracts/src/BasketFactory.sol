// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BasketToken} from "./BasketToken.sol";
import {CuratorRegistry} from "./CuratorRegistry.sol";
import {FeeSplitter} from "./FeeSplitter.sol";

/// @title BasketFactory — anyone can publish an index
/// @notice The factory of the curation platform: any address holding a
///         curation license (earned by burning VIM, see CuratorRegistry) can
///         deploy a basket. The factory wires every basket the same
///         trust-minimized way:
///         - feeRecipient = the FeeSplitter (60% to the curator / 40% treasury,
///           constants — the curator can never redirect fees);
///         - guardian    = the CuratorGuardian, a restricted guardian that can
///           only advance the supply cap upward and has NO power to redirect
///           fees or pause minting. So on a curated basket the fee stream to
///           the curator can never be diverted or choked by anyone, including
///           the protocol — only the cap roadmap applies.
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
    address public immutable basketGuardian;

    address[] private _baskets;
    mapping(address basket => address curator) public curatorOf;

    constructor(CuratorRegistry registry_, FeeSplitter splitter_, address basketGuardian_) {
        if (address(registry_) == address(0) || address(splitter_) == address(0) || basketGuardian_ == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        splitter = splitter_;
        basketGuardian = basketGuardian_;
    }

    /// @notice Publish a basket. Requires a curation license
    ///         (earned by burning VIM, `registry.isLicensed(msg.sender)`).
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
                basketGuardian,
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
