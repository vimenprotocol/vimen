// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VimenZap} from "../src/VimenZap.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4.sol";

/// Single-constituent stub so the deployed zap can quote one leg at a time.
contract OneTokenBasket {
    address public token;
    uint256 public unitPerBasket;

    constructor(address _token, uint256 _unit) {
        token = _token;
        unitPerBasket = _unit;
    }

    function getRequiredUnits(uint256 basketAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address[](1);
        amounts = new uint256[](1);
        tokens[0] = token;
        // ceil, same as BasketToken
        amounts[0] = (unitPerBasket * basketAmount + 1e18 - 1) / 1e18;
    }
}

/// Read-only diagnosis of MAG7 zap legs: quotes each leg alone through the
/// LIVE VimenZap via simulation. Never broadcast.
contract QuoteDebug is Script {
    VimenZap constant ZAP = VimenZap(payable(0x0bFE35e6C22aDB35139841c8c9BeA367bc627458));
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH = address(0);

    function _key(address c0, address c1, uint24 fee, int24 ts) internal pure returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: ts, hooks: address(0)});
    }

    function _quoteLeg(string memory name, address token, uint256 unit, VimenZap.Hop[] memory route) internal {
        OneTokenBasket b = new OneTokenBasket(token, unit);
        VimenZap.Hop[][] memory legs = new VimenZap.Hop[][](1);
        legs[0] = route;
        // 0.01 basket
        try ZAP.quoteZapMint(address(b), 1e16, USDG, legs) returns (uint256 totalIn, uint256[] memory) {
            console.log("%s : OK, cost USDG(6d) =", name, totalIn);
        } catch Error(string memory reason) {
            console.log("%s : REVERT '%s'", name, reason);
        } catch (bytes memory data) {
            console.log("%s : REVERT raw (custom error)", name);
            console.logBytes4(bytes4(data));
        }
    }

    function _usdgRoute(address stock, bool usdgIsZero, uint24 fee, int24 ts)
        internal
        pure
        returns (VimenZap.Hop[] memory r)
    {
        r = new VimenZap.Hop[](1);
        r[0] = VimenZap.Hop({
            key: usdgIsZero ? _key(USDG, stock, fee, ts) : _key(stock, USDG, fee, ts),
            zeroForOne: usdgIsZero
        });
    }

    function _ethRoute(address stock, uint24 fee, int24 ts) internal pure returns (VimenZap.Hop[] memory r) {
        r = new VimenZap.Hop[](2);
        r[0] = VimenZap.Hop({key: _key(ETH, USDG, 500, 10), zeroForOne: false});
        r[1] = VimenZap.Hop({key: _key(ETH, stock, fee, ts), zeroForOne: true});
    }

    function run() external {
        // MAG7 legs, units per 1e18 basket from baskets/mag7.json
        _quoteLeg("AAPL ", 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 45279601539506452, _usdgRoute(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, true, 500, 10));
        _quoteLeg("MSFT ", 0xe93237C50D904957Cf27E7B1133b510C669c2e74, 37135652826208858, _usdgRoute(0xe93237C50D904957Cf27E7B1133b510C669c2e74, true, 20000, 400));
        _quoteLeg("GOOGL", 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 40047416140710601, _usdgRoute(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, false, 9000, 180));
        _quoteLeg("AMZN ", 0x12f190a9F9d7D37a250758b26824B97CE941bF54, 58174239876475146, _ethRoute(0x12f190a9F9d7D37a250758b26824B97CE941bF54, 10000, 200));
        _quoteLeg("META ", 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, 21300506923309090, _usdgRoute(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, true, 3000, 60));
        _quoteLeg("NVDA ", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 67965718091794498, _usdgRoute(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, true, 3000, 60));
        _quoteLeg("TSLA ", 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 35029030308868474, _usdgRoute(0x322F0929c4625eD5bAd873c95208D54E1c003b2d, false, 3000, 60));

        address GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
        address AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
        address HOODRAT = 0x8e62F281f282686fCa6dCB39288069a93fC23F1c;
        console.log("--- GOOGL candidates (oracle $0.1427 per 0.01 basket) ---");
        _quoteLeg("GOOGL usdg 1%/200 ", GOOGL, 40047416140710601, _usdgRoute(GOOGL, false, 10000, 200));
        _quoteLeg("GOOGL usdg 5%/1000", GOOGL, 40047416140710601, _usdgRoute(GOOGL, false, 50000, 1000));
        _quoteLeg("GOOGL eth 1%/200  ", GOOGL, 40047416140710601, _ethRoute(GOOGL, 10000, 200));
        _quoteLeg("GOOGL eth .01%/1  ", GOOGL, 40047416140710601, _ethRoute(GOOGL, 100, 1));
        console.log("--- AMZN candidates (oracle $0.1428) ---");
        _quoteLeg("AMZN usdg 2%/400  ", AMZN, 58174239876475146, _usdgRoute(AMZN, false, 20000, 400));
        console.log("--- AI6 leg isolation (0.2 basket, ~$3.3/leg) ---");
        _quoteLeg("ai6 NVDA ", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 79293337773760248, _usdgRoute(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, true, 3000, 60));
        _quoteLeg("ai6 AMD  ", 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 29857333598585885, _usdgRoute(0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, true, 10000, 200));
        _quoteLeg("ai6 MU   ", 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 17032118009959156, _usdgRoute(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, true, 10000, 200));
        _quoteLeg("ai6 PLTR ", 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 131688387349276056, _ethRoute(0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 10000, 200));
        _quoteLeg("ai6 GOOGL", 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 46721985497495701, _usdgRoute(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, false, 10000, 200));
        _quoteLeg("ai6 SPCX ", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 114370675358837993, _usdgRoute(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, false, 3000, 60));
        console.log("--- PLTR/SPCX candidates (0.2 basket AI6) ---");
        _quoteLeg("PLTR usdg 1%/200", 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 131688387349276056, _usdgRoute(0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, true, 10000, 200));
        _quoteLeg("SPCX usdg 1%/200", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 114370675358837993, _usdgRoute(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, false, 10000, 200));
        _quoteLeg("SPCX eth  1%/200", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 114370675358837993, _ethRoute(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 10000, 200));
        console.log("--- MAG7 capacity probe (real basket, sizes in baskets) ---");
        {
            address MAG7 = 0xe1c1ADAD813736427B334e798fd2EbC7d2C7A9DF;
            VimenZap.Hop[][] memory ml = new VimenZap.Hop[][](7);
            ml[0] = _usdgRoute(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, true, 500, 10);
            ml[1] = _usdgRoute(0xe93237C50D904957Cf27E7B1133b510C669c2e74, true, 20000, 400);
            ml[2] = _usdgRoute(GOOGL, false, 10000, 200);
            ml[3] = _usdgRoute(AMZN, false, 20000, 400);
            ml[4] = _usdgRoute(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, true, 3000, 60);
            ml[5] = _usdgRoute(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, true, 3000, 60);
            ml[6] = _usdgRoute(0x322F0929c4625eD5bAd873c95208D54E1c003b2d, false, 3000, 60);
            uint256[8] memory sizes = [uint256(5e17), 1e18, 2e18, 3e18, 5e18, 8e18, 12e18, 20e18];
            for (uint256 i = 0; i < sizes.length; i++) {
                try ZAP.quoteZapMint(MAG7, sizes[i], USDG, ml) returns (uint256 tot, uint256[] memory li) {
                    // oracle: $100/basket -> premio complessivo
                    uint256 oracle = sizes[i] * 100e6 / 1e18;
                    console.log("size(1e18)=%s costUSDG=%s oracleUSDG=%s", sizes[i], tot, oracle);
                    console.log("   worst leg USDG: MSFT=%s AMZN=%s GOOGL=%s", li[1], li[3], li[2]);
                } catch {
                    console.log("size(1e18)=%s REVERT (una pool non riempie)", sizes[i]);
                }
            }
        }
        console.log("--- HOODRAT at 0.1 basket (oracle ~$1.23) ---");
        OneTokenBasket hb = new OneTokenBasket(HOODRAT, 1842581618995395020017);
        VimenZap.Hop[][] memory hl = new VimenZap.Hop[][](1);
        hl[0] = _ethRoute(HOODRAT, 10000, 200);
        try ZAP.quoteZapMint(address(hb), 1e17, USDG, hl) returns (uint256 t, uint256[] memory) {
            console.log("HOODRAT 0.1 basket: OK, cost USDG(6d) =", t);
        } catch { console.log("HOODRAT 0.1 basket: REVERT"); }
    }
}
