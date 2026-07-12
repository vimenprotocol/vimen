// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VimenZap} from "../src/VimenZap.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4.sol";

/// Read-only capacity probe: quotes the live HOOD6 and AI6 baskets through
/// the deployed router at growing sizes and prints per-leg costs, to find
/// which pool caps each basket. Never broadcast.
contract CapacityProbe is Script {
    VimenZap constant ZAP = VimenZap(payable(0x0bFE35e6C22aDB35139841c8c9BeA367bc627458));
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH = address(0);

    function _key(address c0, address c1, uint24 fee, int24 ts) internal pure returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: ts, hooks: address(0)});
    }

    function _usdg(address stock, bool usdgIsZero, uint24 fee, int24 ts) internal pure returns (VimenZap.Hop[] memory r) {
        r = new VimenZap.Hop[](1);
        r[0] = VimenZap.Hop({key: usdgIsZero ? _key(USDG, stock, fee, ts) : _key(stock, USDG, fee, ts), zeroForOne: usdgIsZero});
    }

    function _eth(address stock, uint24 fee, int24 ts) internal pure returns (VimenZap.Hop[] memory r) {
        r = new VimenZap.Hop[](2);
        r[0] = VimenZap.Hop({key: _key(ETH, USDG, 500, 10), zeroForOne: false});
        r[1] = VimenZap.Hop({key: _key(ETH, stock, fee, ts), zeroForOne: true});
    }

    function _probe(string memory name, address basket, VimenZap.Hop[][] memory legs, string[] memory names) internal {
        uint256[7] memory sizes = [uint256(2e17), 5e17, 1e18, 2e18, 3e18, 5e18, 8e18];
        console.log("=== %s ===", name);
        for (uint256 i = 0; i < sizes.length; i++) {
            try ZAP.quoteZapMint(basket, sizes[i], USDG, legs) returns (uint256 tot, uint256[] memory li) {
                console.log(" size=%s baskets/100 -> cost USDG(6d)=%s", sizes[i] / 1e16, tot);
                for (uint256 j = 0; j < li.length; j++) {
                    console.log("    %s = %s", names[j], li[j]);
                }
            } catch {
                console.log(" size=%s baskets/100 -> REVERT", sizes[i] / 1e16);
            }
        }
    }

    function run() external {
        // HOOD6
        {
            VimenZap.Hop[][] memory l = new VimenZap.Hop[][](6);
            l[0] = _usdg(0x020bfC650A365f8BB26819deAAbF3E21291018b4, false, 5000, 100); // CASHCAT
            l[1] = _eth(0xf2915d1e3C1B0c769d0c756Ec43F1c1f6c99cD03, 10000, 200); // ARROW
            l[2] = _eth(0x8e62F281f282686fCa6dCB39288069a93fC23F1c, 10000, 200); // HOODRAT
            l[3] = _eth(0x2355431b83B1A8E40172D099d90243D8D666b56B, 10000, 200); // VIBECAT
            l[4] = _usdg(0x8Ff92566f2e81BDd68EDfAa8cde73942A723796b, true, 10000, 200); // VEX
            l[5] = _usdg(0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31, true, 3000, 60); // VIRTUAL
            string[] memory n = new string[](6);
            n[0] = "CASHCAT"; n[1] = "ARROW"; n[2] = "HOODRAT"; n[3] = "VIBECAT"; n[4] = "VEX"; n[5] = "VIRTUAL";
            _probe("HOOD6", 0x0CE04932513Fa1768B5b9444c6A21Ae0DdA005C5, l, n);
        }
        // AI6
        {
            VimenZap.Hop[][] memory l = new VimenZap.Hop[][](6);
            l[0] = _usdg(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, true, 3000, 60); // NVDA
            l[1] = _usdg(0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, true, 10000, 200); // AMD
            l[2] = _usdg(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, true, 10000, 200); // MU
            l[3] = _usdg(0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, true, 10000, 200); // PLTR
            l[4] = _usdg(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, false, 10000, 200); // GOOGL
            l[5] = _usdg(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, false, 10000, 200); // SPCX
            string[] memory n = new string[](6);
            n[0] = "NVDA"; n[1] = "AMD"; n[2] = "MU"; n[3] = "PLTR"; n[4] = "GOOGL"; n[5] = "SPCX";
            _probe("AI6", 0x8fF1d77a09A3292b34457175710Bb0C0A1C22601, l, n);
        }
    }
}
