// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Random sequence driver: it is the vault owner and acts as owner, beneficiaries and keepers.
contract VaultHandler is Test {
    VestingVault public immutable vault;
    MockERC20 public immutable token;
    address[] public actors;

    constructor(VestingVault vault_, MockERC20 token_) {
        vault = vault_;
        token = token_;
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1e30);
        token.mint(address(vault), amount);
    }

    function create(uint256 actorSeed, uint256 amount, uint64 cliff, uint64 duration, uint32 startOffset, bool revocable) external {
        uint256 free = vault.unallocated();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        duration = uint64(bound(duration, 1, 4 * 365 days));
        cliff = uint64(bound(cliff, 0, duration));
        uint64 start = uint64(block.timestamp) + uint64(bound(startOffset, 0, 365 days));
        vault.createSchedule(actors[actorSeed % actors.length], amount, start, cliff, duration, revocable);
    }

    function release(uint256 idSeed) external {
        uint256 n = vault.scheduleCount();
        if (n == 0) return;
        uint256 id = bound(idSeed, 1, n);
        if (vault.releasable(id) == 0) return;
        vault.release(id);
    }

    function revoke(uint256 idSeed) external {
        uint256 n = vault.scheduleCount();
        if (n == 0) return;
        uint256 id = bound(idSeed, 1, n);
        (,,,,,,, bool revocable, bool revoked) = vault.schedules(id);
        if (!revocable || revoked) return;
        vault.revoke(id);
    }

    function transfer(uint256 idSeed, uint256 actorSeed) external {
        uint256 n = vault.scheduleCount();
        if (n == 0) return;
        uint256 id = bound(idSeed, 1, n);
        (address b,,,,,,,,) = vault.schedules(id);
        vm.prank(b);
        vault.transferSchedule(id, actors[actorSeed % actors.length]);
    }

    function withdraw() external {
        if (vault.unallocated() == 0) return;
        vault.withdrawUnallocated(address(this));
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 180 days));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract VestingVaultInvariantTest is Test {
    VestingVault vault;
    MockERC20 token;
    VaultHandler handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20("Test Token", "TST");
        vault = new VestingVault(token);
        handler = new VaultHandler(vault, token);
        vault.transferOwnership(address(handler));
        targetContract(address(handler));
    }

    /// The vault can always pay every promise.
    function invariant_BalanceCoversAllocations() public view {
        assertGe(token.balanceOf(address(vault)), vault.totalAllocated());
    }

    /// totalAllocated equals the sum of what every schedule can still pay out.
    function invariant_TotalAllocatedMatchesSchedules() public view {
        uint256 sum;
        uint256 n = vault.scheduleCount();
        for (uint256 id = 1; id <= n; ++id) {
            (, uint256 total, uint256 released,,,,, , bool revoked) = vault.schedules(id);
            uint256 cap = revoked ? vault.vestedAmount(id) : total;
            assertLe(released, cap);
            sum += cap - released;
        }
        assertEq(sum, vault.totalAllocated());
    }

    /// Every schedule is listed exactly under its current beneficiary.
    function invariant_SchedulesOfIsConsistent() public view {
        uint256 listed;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            uint256[] memory ids = vault.schedulesOf(a);
            listed += ids.length;
            for (uint256 j; j < ids.length; ++j) {
                (address b,,,,,,,,) = vault.schedules(ids[j]);
                assertEq(b, a);
            }
        }
        assertEq(listed, vault.scheduleCount());
    }
}
