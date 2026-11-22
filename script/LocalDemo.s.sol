// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Local playground for the frontend: mock token + vault + a few schedules.
/// anvil   (in another terminal)
/// forge script script/LocalDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///   --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract LocalDemo is Script {
    // anvil default accounts #1 and #2
    address constant TEAM = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ADVISOR = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external {
        vm.startBroadcast();
        MockERC20 token = new MockERC20("Demo Token", "DEMO");
        VestingVault vault = new VestingVault(token);
        token.mint(msg.sender, 10_000_000 ether);
        token.transfer(address(vault), 5_000_000 ether);

        uint64 nowTs = uint64(block.timestamp);
        // retroactive: started 13 months ago, 12-month cliff, 48 months total -> already past the cliff
        vault.createSchedule(TEAM, 1_000_000 ether, nowTs - 395 days, 365 days, 4 * 365 days, true);
        // short demo schedule: 5 min cliff, 1 hour linear
        vault.createSchedule(TEAM, 100_000 ether, nowTs, 5 minutes, 1 hours, true);
        vault.createSchedule(ADVISOR, 250_000 ether, nowTs, 0, 30 days, false);
        vm.stopBroadcast();

        console.log("Token:", address(token));
        console.log("Vault:", address(vault));
    }
}
