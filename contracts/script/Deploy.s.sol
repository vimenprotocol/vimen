// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BasketToken} from "../src/BasketToken.sol";

/// Deploys one basket from a JSON config produced by scripts/computeUnits.ts.
///
///   forge script script/Deploy.s.sol \
///     --sig "run(string)" baskets/mag7.json \
///     --rpc-url $RH_RPC --broadcast \
///     --verify --verifier blockscout \
///     --verifier-url https://robinhoodchain.blockscout.com/api
///
/// HUMAN CHECKPOINT (hard requirement, spec §4.7): the script prints the full
/// resolved config and refuses to broadcast unless CONFIRM_DEPLOY=yes is set.
/// Review the printout with --broadcast omitted first.
contract Deploy is Script {
    using stdJson for string;

    function run(string memory configPath) external {
        require(block.chainid == 4663, "wrong chain: expected Robinhood Chain (4663)");

        string memory json = vm.readFile(configPath);

        string memory name = json.readString(".name");
        string memory symbol = json.readString(".symbol");
        address[] memory tokens = json.readAddressArray(".tokens");
        uint256[] memory unitsPerBasket = json.readUintArray(".unitsPerBasket");
        uint256 mintFeeBpsRaw = json.readUint(".mintFeeBps");
        require(mintFeeBpsRaw <= type(uint16).max, "mintFeeBps overflows uint16");
        uint16 mintFeeBps = uint16(mintFeeBpsRaw);
        address feeRecipient = json.readAddress(".feeRecipient");
        address guardian = json.readAddress(".guardian");
        uint256 maxSupplyCap = json.readUint(".maxSupplyCap");
        uint256 initialSupplyCap = json.readUint(".initialSupplyCap");

        // The guardian is immutable and the feeRecipient collects real value:
        // both must be live contracts (the Safe) on THIS chain before any
        // basket references them.
        require(guardian.code.length > 0, "guardian has no code on this chain (deploy the Safe first)");
        require(feeRecipient.code.length > 0, "feeRecipient has no code on this chain (deploy the Safe first)");

        console.log("=== Resolved basket config ===");
        console.log("name:            %s", name);
        console.log("symbol:          %s", symbol);
        console.log("mintFeeBps:      %s", mintFeeBps);
        console.log("feeRecipient:    %s", feeRecipient);
        console.log("guardian:        %s", guardian);
        console.log("maxSupplyCap:    %s", maxSupplyCap);
        console.log("initialSupplyCap:%s", initialSupplyCap);
        console.log("constituents (on-chain symbol / address / units):");
        for (uint256 i = 0; i < tokens.length; i++) {
            // Read symbol+decimals from the live chain so a wrong or fake
            // address is visible at the checkpoint.
            string memory sym = IERC20Metadata(tokens[i]).symbol();
            uint8 dec = IERC20Metadata(tokens[i]).decimals();
            require(dec == 18, "constituent is not 18 decimals");
            console.log("  %s  %s  units=%s", sym, tokens[i], unitsPerBasket[i]);
        }

        if (!_confirmed()) {
            console.log("");
            console.log("DRY RUN ONLY. Set CONFIRM_DEPLOY=yes to allow broadcast.");
            return;
        }

        vm.startBroadcast();
        BasketToken basket = new BasketToken(
            name, symbol, tokens, unitsPerBasket, mintFeeBps, feeRecipient, guardian, maxSupplyCap, initialSupplyCap
        );
        vm.stopBroadcast();

        console.log("");
        console.log("Deployed %s at %s", symbol, address(basket));
        require(basket.isFullyBacked(), "sanity: empty basket must be fully backed");
    }

    function _confirmed() internal view returns (bool) {
        return keccak256(bytes(vm.envOr("CONFIRM_DEPLOY", string("")))) == keccak256("yes");
    }
}
