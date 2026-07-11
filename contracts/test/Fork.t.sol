// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken} from "../src/BasketToken.sol";

/// Mainnet-fork test against the real Stock Token contracts on Robinhood
/// Chain (chain id 4663). Runs only when RH_RPC is set:
///
///   RH_RPC=https://... forge test --match-contract ForkTest
///
/// Addresses below are the canonical MAG7 constituents as listed on
/// https://docs.robinhood.com/chain/contracts on 2026-07-10. Deployment
/// re-verifies them against the docs (see scripts/computeUnits.ts); this test
/// asserts on-chain sanity (18 decimals, transferability by a contract).
contract ForkTest is Test {
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    address user = makeAddr("forkUser");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");

    address[] tokens;
    uint256[] units;
    BasketToken basket;
    bool active;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC", string(""));
        if (bytes(rpc).length == 0) return; // tests self-skip
        vm.createSelectFork(rpc);
        active = true;

        assertEq(block.chainid, 4663, "not Robinhood Chain");

        tokens = [AAPL, MSFT, GOOGL, AMZN, META, NVDA, TSLA];
        // Placeholder equal raw units; real deployments compute these from
        // live Chainlink prices (scripts/computeUnits.ts).
        for (uint256 i = 0; i < tokens.length; i++) {
            units.push(5e16); // 0.05 raw tokens per basket
        }
        basket = new BasketToken(
            "Magnificent 7 Basket", "MAG7", tokens, units, 30, feeRecipient, guardian, 1_000_000e18, 1_000e18
        );
    }

    modifier onlyFork() {
        vm.skip(!active);
        _;
    }

    /// Required test case 10 (spec §3.1): real tokens report 18 decimals.
    function test_fork_realTokensHave18Decimals() public onlyFork {
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(IERC20Metadata(tokens[i]).decimals(), 18, "stock token not 18 decimals");
        }
    }

    /// Required test case 10 (spec §3.1): full mint → transfer → redeem cycle
    /// against the real Stock Token contracts.
    function test_fork_fullMintTransferRedeemCycle() public onlyFork {
        uint256 amount = 10e18;
        (, uint256[] memory required) = basket.getRequiredUnits(amount);
        for (uint256 i = 0; i < tokens.length; i++) {
            deal(tokens[i], user, required[i]);
            vm.prank(user);
            IERC20(tokens[i]).approve(address(basket), required[i]);
        }

        vm.prank(user);
        basket.mint(amount, user);
        uint256 fee = (amount * 30) / 10_000;
        assertEq(basket.balanceOf(user), amount - fee);
        assertTrue(basket.isFullyBacked());

        // ERC-20 transfer of the basket itself
        address recipient = makeAddr("recipient");
        uint256 net = basket.balanceOf(user);
        vm.prank(user);
        basket.transfer(recipient, net);

        (, uint256[] memory expected) = basket.backingOf(net);
        vm.prank(recipient);
        basket.redeem(net, recipient);
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(IERC20(tokens[i]).balanceOf(recipient), expected[i], "redeem payout mismatch");
        }
        assertTrue(basket.isFullyBacked());
    }
}
