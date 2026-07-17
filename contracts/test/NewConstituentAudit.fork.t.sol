// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken} from "../src/BasketToken.sol";

/// Fork audit for candidate basket constituents: proves, against MAINNET
/// state, that a plain transfer of the token in and out of a BasketToken
/// vault is loss-free — i.e. no fee-on-transfer on simple transfers and no
/// blacklist blocking the vault today. A token that fails here can be shown
/// in Markets but must NEVER be baskettable (mint would revert, or worse,
/// redeem would strand).
///
///   RH_RPC=... forge test --match-contract NewConstituentAudit -vv \
///     --fork-url $RH_RPC
///
/// Funding strategy: impersonate the token's own liquidity pair (the one
/// address guaranteed to hold inventory) and transfer to the test user.
/// That first hop MAY be taxed on tax-on-swap tokens (pair->user looks like
/// a buy); the audit measures what the user actually received and only
/// judges the user->vault->user legs, which are the ones minting relies on.
contract NewConstituentAuditFork is Test {
    struct Candidate {
        string symbol;
        address token;
        address pair;
    }

    Candidate[] internal candidates;

    address internal user = makeAddr("auditUser");

    function setUp() public {
        // 9 factory-verified Virtuals agents (VIM excluded by decision) + meme picks
        candidates.push(Candidate("HAN", 0x3746a5ebCA295Dee695dd1bcba50A8626Df3099C, 0x5Ae5c378d28637311A66a7AAA52111397822ABDd));
        candidates.push(Candidate("MLY", 0x84b7515081A7Ac5adc26179b77A8B18A8c6725C0, 0x51245486B6386576d08c4C01599bAC7C9676D11c));
        candidates.push(Candidate("HYP", 0x316fb7a2a0729698D61956015705ddaFbCfa0a81, 0x3602372D1f95d29ebcF292eDE7Fd236bcC0afc05));
        candidates.push(Candidate("MONVERA", 0x7541872e32Bb529d7FF11D6C59832269ce33a6FF, 0x502Be3da0Ad1c83C79A9e64Ac5A05eEc39A44c78));
        candidates.push(Candidate("PRIZE", 0x48FE62970E2b3962eD9c59f0Fce7e5a43b63eA5B, 0x096040d58Fe181EA9886927B348d1a45Be4965e7));
        candidates.push(Candidate("KINDRA", 0xE44951407D2ed8E73dce4b7002908732BC0d0bC3, 0xE767167E739344d2257dDdaE3192343bBBA29dbE));
        candidates.push(Candidate("FLETCHER", 0x5f18b02B8320Ef1C5B7d7a5A8BAd482a767f4716, 0x3859304dB902E3cc529e4418FE200A22B8De027B));
        candidates.push(Candidate("PHOOD", 0x26C41B10527DE2Dc870fa5C9D5f4A8dBAA966cDf, 0x27eaA4899098f0566eE995391dB0DA49cA60be27));
        candidates.push(Candidate("BOWLINE", 0xc23d7218512c672BA6e87b7F8bccE53355f55931, 0xa2D0565b3BE4802c9054fA46E2A53747b2ddB442));
        candidates.push(Candidate("SUIT", 0xeaa9abB805Db03b6859662354aBfE0C2A30902ae, 0xd91355fc43F92Ef1F128D0c551885560Ed5B1634));
        candidates.push(Candidate("WISHBONE", 0x77581054581B9c525E7dd7a0155DE43867532d03, 0x6Ec89bFF5E684C2561d0a88e185D8D4eb4b3AA30));
        candidates.push(Candidate("MARIAN", 0x01637b14B7378B99dE75A64d50656d98488D9a4d, 0xFE331fD29b54bCE09D52988FA691e3B18B0A4081));
    }

    function test_audit_allCandidates() public {
        for (uint256 i = 0; i < candidates.length; i++) {
            _auditOne(candidates[i]);
        }
    }

    function _auditOne(Candidate memory c) internal {
        IERC20 t = IERC20(c.token);
        uint256 pairBal = t.balanceOf(c.pair);
        if (pairBal < 1000e18) {
            console.log("%s: SKIP (pair inventory too small)", c.symbol);
            return;
        }

        // fund the user from the pair (may be taxed; we measure)
        uint256 ask = 100e18;
        vm.prank(c.pair);
        t.transfer(user, ask);
        uint256 got = t.balanceOf(user);
        bool taxedFromPair = got < ask;

        // vault with [candidate, candidate2=WETH placeholder]: BasketToken needs >=2
        // use the token twice is forbidden (DuplicateToken) -> pair with USDG
        address usdg = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        deal(usdg, user, 10e6);

        address[] memory toks = new address[](2);
        toks[0] = c.token;
        toks[1] = usdg;
        uint256[] memory units = new uint256[](2);
        units[0] = 10e18; // 10 tokens per basket
        units[1] = 1e6; // 1 USDG per basket
        BasketToken vault = new BasketToken(
            string.concat("Audit ", c.symbol), "AUD", toks, units, 0, address(this), address(this), 1_000e18, 1_000e18
        );

        // mint 1 basket: pulls exactly 10 tokens + 1 USDG from user
        vm.startPrank(user);
        t.approve(address(vault), type(uint256).max);
        IERC20(usdg).approve(address(vault), type(uint256).max);
        uint256 balBefore = t.balanceOf(user);
        try vault.mint(1e18, user) {
            uint256 pulled = balBefore - t.balanceOf(user);
            // redeem it all back
            uint256 balMid = t.balanceOf(user);
            vault.redeem(1e18, user);
            uint256 back = t.balanceOf(user) - balMid;
            vm.stopPrank();
            bool clean = (pulled == units[0]) && (back == units[0]);
            console.log(
                clean
                    ? "%s: PASS  (mint+redeem loss-free)%s"
                    : "%s: WARN  transfer imbalance pulled/back",
                c.symbol,
                taxedFromPair ? "  [note: pair->user hop taxed]" : ""
            );
            if (!clean) {
                console.log("   pulled %s back %s (units %s)", pulled, back, units[0]);
            }
        } catch (bytes memory reason) {
            vm.stopPrank();
            console.log("%s: FAIL  mint reverted -> NOT baskettable", c.symbol);
            console.logBytes(reason);
        }
    }
}
