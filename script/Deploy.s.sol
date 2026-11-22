// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingVault} from "../src/VestingVault.sol";

/// @notice Deploys a VestingVault for an existing token.
/// forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
contract Deploy is Script {
    function run() external returns (VestingVault vault) {
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        vm.startBroadcast();
        vault = new VestingVault(IERC20(tokenAddr));
        vm.stopBroadcast();
        console.log("VestingVault:", address(vault));
    }
}
