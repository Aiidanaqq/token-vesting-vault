// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {CallbackToken, ReentrantBeneficiary} from "./mocks/CallbackToken.sol";

contract VestingVaultTest is Test {
    MockERC20 token;
    VestingVault vault;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint64 constant START = 100_000;
    uint64 constant CLIFF = 200;
    uint64 constant DURATION = 1000;
    uint256 constant TOTAL = 1_000_000;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration, bool revocable);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 returnedToOwner);
    event ScheduleTransferred(uint256 indexed id, address indexed from, address indexed to);

    function setUp() public {
        vm.warp(START - 1000);
        token = new MockERC20("Test Token", "TST");
        vm.prank(owner);
        vault = new VestingVault(token);
        token.mint(address(vault), 10 * TOTAL);
    }

    function _create(address who, uint256 amount, bool revocable) internal returns (uint256) {
        vm.prank(owner);
        return vault.createSchedule(who, amount, START, CLIFF, DURATION, revocable);
    }

    function _vestedAt(uint256 id, uint256 t) internal returns (uint256) {
        vm.warp(t);
        return vault.vestedAmount(id);
    }

    // ------------------------------------------------------------
    // createSchedule
    // ------------------------------------------------------------

    function test_CreateSchedule_StoresEverything() public {
        vm.expectEmit(true, true, false, true);
        emit ScheduleCreated(1, alice, TOTAL, START, CLIFF, DURATION, true);
        uint256 id = _create(alice, TOTAL, true);

        assertEq(id, 1);
        assertEq(vault.scheduleCount(), 1);
        assertEq(vault.totalAllocated(), TOTAL);
        (address b, uint256 total, uint256 released, uint64 start, uint64 cliff, uint64 duration, uint64 revokedAt, bool revocable, bool revoked) =
            vault.schedules(id);
        assertEq(b, alice);
        assertEq(total, TOTAL);
        assertEq(released, 0);
        assertEq(start, START);
        assertEq(cliff, CLIFF);
        assertEq(duration, DURATION);
        assertEq(revokedAt, 0);
        assertTrue(revocable);
        assertFalse(revoked);

        uint256 id2 = _create(alice, 1, false);
        assertEq(id2, 2);
        uint256[] memory ids = vault.schedulesOf(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function test_CreateSchedule_Validation() public {
        vm.startPrank(owner);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        vault.createSchedule(address(0), TOTAL, START, CLIFF, DURATION, true);

        vm.expectRevert(VestingVault.ZeroAmount.selector);
        vault.createSchedule(alice, 0, START, CLIFF, DURATION, true);

        vm.expectRevert(VestingVault.ZeroDuration.selector);
        vault.createSchedule(alice, TOTAL, START, 0, 0, true);

        vm.expectRevert(VestingVault.CliffExceedsDuration.selector);
        vault.createSchedule(alice, TOTAL, START, DURATION + 1, DURATION, true);

        // cliff == duration is allowed
        vault.createSchedule(alice, TOTAL, START, DURATION, DURATION, true);
        vm.stopPrank();
    }

    function test_CreateSchedule_CannotOverpromise() public {
        _create(alice, 6 * TOTAL, true);
        _create(bob, 4 * TOTAL, true); // exactly the remaining 4 * TOTAL

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.InsufficientUnallocated.selector, 0, 1));
        vault.createSchedule(bob, 1, START, CLIFF, DURATION, true);
    }

    function test_CreateSchedule_RetroactiveStartInPast() public {
        vm.warp(START + 500);
        vm.prank(owner);
        uint256 id = vault.createSchedule(alice, TOTAL, START, CLIFF, DURATION, false);
        assertEq(vault.vestedAmount(id), 500_000);
        assertEq(vault.releasable(id), 500_000);
    }

    // ------------------------------------------------------------
    // vestedAmount / releasable
    // ------------------------------------------------------------

    function test_VestedAmount_ExampleTable() public {
        uint256 id = _create(alice, TOTAL, true);
        assertEq(_vestedAt(id, START - 10), 0, "before start");
        assertEq(_vestedAt(id, START + 199), 0, "inside cliff");
        assertEq(_vestedAt(id, START + 200), 200_000, "cliff edge");
        assertEq(_vestedAt(id, START + 500), 500_000, "middle");
        assertEq(_vestedAt(id, START + 777), 777_000, "linear");
        assertEq(_vestedAt(id, START + 1000), TOTAL, "end");
        assertEq(_vestedAt(id, START + 5000), TOTAL, "after end");
    }

    function test_VestedAmount_RoundsDown() public {
        vm.prank(owner);
        uint256 id = vault.createSchedule(alice, 1000, START, 0, 3, false);
        assertEq(_vestedAt(id, START), 0);
        assertEq(_vestedAt(id, START + 1), 333);
        assertEq(_vestedAt(id, START + 2), 666);
        assertEq(_vestedAt(id, START + 3), 1000);
    }

    function test_VestedAmount_CliffEqualsDuration() public {
        vm.prank(owner);
        uint256 id = vault.createSchedule(alice, TOTAL, START, DURATION, DURATION, false);
        assertEq(_vestedAt(id, START + DURATION - 1), 0);
        assertEq(_vestedAt(id, START + DURATION), TOTAL);
    }

    function test_VestedAmount_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(VestingVault.UnknownSchedule.selector, 42));
        vault.vestedAmount(42);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.UnknownSchedule.selector, 0));
        vault.releasable(0);
    }

    // ------------------------------------------------------------
    // release
    // ------------------------------------------------------------

    function test_Release_MultipleTimesSumsToTotal() public {
        uint256 id = _create(alice, TOTAL, true);
        uint64[5] memory checkpoints = [START + 200, START + 333, START + 500, START + 999, START + 2000];
        for (uint256 i; i < checkpoints.length; ++i) {
            vm.warp(checkpoints[i]);
            vault.release(id);
        }
        assertEq(token.balanceOf(alice), TOTAL);
        assertEq(vault.totalAllocated(), 0);
        assertEq(vault.releasable(id), 0);

        vm.expectRevert(VestingVault.NothingToRelease.selector);
        vault.release(id);
    }

    function test_Release_AnyoneCanTrigger_TokensGoToBeneficiary() public {
        uint256 id = _create(alice, TOTAL, true);
        vm.warp(START + 500);

        vm.expectEmit(true, true, false, true);
        emit Released(id, alice, 500_000);
        vm.prank(mallory);
        vault.release(id);

        assertEq(token.balanceOf(alice), 500_000);
        assertEq(token.balanceOf(mallory), 0);
        assertEq(vault.totalAllocated(), TOTAL - 500_000);
    }

    function test_Release_RevertsWhenNothingOrUnknown() public {
        uint256 id = _create(alice, TOTAL, true);
        vm.warp(START + 100); // inside cliff
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        vault.release(id);

        vm.expectRevert(abi.encodeWithSelector(VestingVault.UnknownSchedule.selector, 7));
        vault.release(7);
    }

    function test_Release_ReentrancyAttackFails() public {
        CallbackToken cbt = new CallbackToken();
        vm.prank(owner);
        VestingVault v = new VestingVault(cbt);
        cbt.mint(address(v), 2 * TOTAL);

        ReentrantBeneficiary attacker = new ReentrantBeneficiary(v);
        cbt.setHooked(address(attacker), true);

        vm.startPrank(owner);
        uint256 id = v.createSchedule(address(attacker), TOTAL, START, CLIFF, DURATION, false);
        v.createSchedule(bob, TOTAL, START, CLIFF, DURATION, false); // victim funds in the same vault
        vm.stopPrank();
        attacker.setId(id);

        vm.warp(START + 500);
        v.release(id);

        assertGt(attacker.attempts(), 0, "hook must have fired");
        assertFalse(attacker.reentrySucceeded());
        assertEq(cbt.balanceOf(address(attacker)), 500_000);
        assertEq(v.totalAllocated(), 2 * TOTAL - 500_000);
        assertEq(cbt.balanceOf(address(v)), 2 * TOTAL - 500_000);
    }

    // ------------------------------------------------------------
    // revoke
    // ------------------------------------------------------------

    function test_Revoke_BeforeCliff_ReturnsEverything() public {
        uint256 id = _create(alice, TOTAL, true);
        vm.warp(START + 100);

        vm.expectEmit(true, false, false, true);
        emit Revoked(id, TOTAL);
        vm.prank(owner);
        vault.revoke(id);

        assertEq(token.balanceOf(owner), TOTAL);
        assertEq(vault.totalAllocated(), 0);
        vm.warp(START + 10 * DURATION);
        assertEq(vault.vestedAmount(id), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        vault.release(id);
    }

    function test_Revoke_Middle_FreezesVesting() public {
        uint256 id = _create(alice, TOTAL, true);
        vm.warp(START + 300);
        vault.release(id); // alice already took 300k

        vm.warp(START + 500);
        vm.prank(owner);
        vault.revoke(id);

        assertEq(token.balanceOf(owner), 500_000, "unvested returned");
        assertEq(vault.totalAllocated(), 200_000, "only alice's vested-unreleased part remains");

        (,,,,,, uint64 revokedAt,, bool revoked) = vault.schedules(id);
        assertTrue(revoked);
        assertEq(revokedAt, START + 500);

        // ten years later alice still gets only what was vested at revocation
        vm.warp(START + 10 * 365 days);
        assertEq(vault.vestedAmount(id), 500_000);
        assertEq(vault.releasable(id), 200_000);
        vault.release(id);
        assertEq(token.balanceOf(alice), 500_000);
        assertEq(vault.totalAllocated(), 0);

        vm.expectRevert(VestingVault.NothingToRelease.selector);
        vault.release(id);
    }

    function test_Revoke_AfterEnd_ReturnsZero() public {
        uint256 id = _create(alice, TOTAL, true);
        vm.warp(START + DURATION + 1);
        vm.prank(owner);
        vault.revoke(id);
        assertEq(token.balanceOf(owner), 0);
        assertEq(vault.releasable(id), TOTAL);
        vault.release(id);
        assertEq(token.balanceOf(alice), TOTAL);
    }

    function test_Revoke_RevertsForNonRevocableOrTwice() public {
        uint256 fixedId = _create(alice, TOTAL, false);
        uint256 id = _create(bob, TOTAL, true);

        vm.startPrank(owner);
        vm.expectRevert(VestingVault.NotRevocable.selector);
        vault.revoke(fixedId);

        vault.revoke(id);
        vm.expectRevert(VestingVault.AlreadyRevoked.selector);
        vault.revoke(id);

        vm.expectRevert(abi.encodeWithSelector(VestingVault.UnknownSchedule.selector, 99));
        vault.revoke(99);
        vm.stopPrank();
    }

    function test_Revoke_FreesAllocationForNewSchedules() public {
        _create(alice, 10 * TOTAL, true); // vault fully promised
        vm.prank(owner);
        vault.revoke(1);
        assertEq(vault.totalAllocated(), 0);

        // owner got tokens back, re-funds and can promise again
        vm.startPrank(owner);
        token.transfer(address(vault), TOTAL);
        vault.createSchedule(bob, TOTAL, START, CLIFF, DURATION, true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------
    // access control
    // ------------------------------------------------------------

    function test_AccessControl_OnlyOwner() public {
        uint256 id = _create(alice, TOTAL, true);

        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        vault.createSchedule(mallory, 1, START, 0, 1, false);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        vault.revoke(id);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        vault.withdrawUnallocated(mallory);
        vm.stopPrank();

        assertEq(token.balanceOf(mallory), 0);
    }

    // ------------------------------------------------------------
    // withdrawUnallocated / schedulesOf
    // ------------------------------------------------------------

    function test_WithdrawUnallocated_OnlySurplus() public {
        _create(alice, 3 * TOTAL, true);
        token.mint(address(vault), 5); // tokens sent by mistake

        vm.prank(owner);
        uint256 amount = vault.withdrawUnallocated(bob);
        assertEq(amount, 7 * TOTAL + 5);
        assertEq(token.balanceOf(bob), 7 * TOTAL + 5);
        assertEq(token.balanceOf(address(vault)), 3 * TOTAL);

        vm.prank(owner);
        vm.expectRevert(VestingVault.NothingToWithdraw.selector);
        vault.withdrawUnallocated(bob);

        // promised tokens are still fully claimable
        vm.warp(START + DURATION);
        vault.release(1);
        assertEq(token.balanceOf(alice), 3 * TOTAL);
    }

    function test_WithdrawUnallocated_ZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        vault.withdrawUnallocated(address(0));
    }

    // ------------------------------------------------------------
    // bonus: transferSchedule
    // ------------------------------------------------------------

    function test_TransferSchedule_MovesOwnershipAndKeepsReleased() public {
        uint256 a1 = _create(alice, TOTAL, true);
        uint256 a2 = _create(alice, TOTAL, true);
        uint256 a3 = _create(alice, TOTAL, true);

        vm.warp(START + 400);
        vault.release(a2);

        vm.expectEmit(true, true, true, true);
        emit ScheduleTransferred(a2, alice, bob);
        vm.prank(alice);
        vault.transferSchedule(a2, bob);

        uint256[] memory ofAlice = vault.schedulesOf(alice);
        assertEq(ofAlice.length, 2);
        assertTrue((ofAlice[0] == a1 && ofAlice[1] == a3) || (ofAlice[0] == a3 && ofAlice[1] == a1));
        uint256[] memory ofBob = vault.schedulesOf(bob);
        assertEq(ofBob.length, 1);
        assertEq(ofBob[0], a2);

        (address b, , uint256 released, , , , , , ) = vault.schedules(a2);
        assertEq(b, bob);
        assertEq(released, 400_000);

        vm.warp(START + DURATION);
        vault.release(a2);
        assertEq(token.balanceOf(bob), 600_000);
        assertEq(token.balanceOf(alice), 400_000);
    }

    function test_TransferSchedule_Restrictions() public {
        uint256 id = _create(alice, TOTAL, true);

        vm.prank(mallory);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        vault.transferSchedule(id, mallory);

        vm.prank(owner);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        vault.transferSchedule(id, owner);

        vm.prank(alice);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        vault.transferSchedule(id, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.UnknownSchedule.selector, 5));
        vault.transferSchedule(5, bob);
    }

    // ------------------------------------------------------------
    // fuzz
    // ------------------------------------------------------------

    /// vestedAmount never exceeds total and never decreases over time.
    function testFuzz_VestedBoundedAndMonotonic(
        uint256 amount,
        uint64 cliff,
        uint64 duration,
        uint32 dt1,
        uint32 dt2
    ) public {
        amount = bound(amount, 1, 10 * TOTAL);
        duration = uint64(bound(duration, 1, 10 * 365 days));
        cliff = uint64(bound(cliff, 0, duration));

        vm.prank(owner);
        uint256 id = vault.createSchedule(alice, amount, START, cliff, duration, true);

        uint256 t1 = uint256(START) - 1000 + dt1;
        uint256 t2 = t1 + dt2;

        uint256 v1 = _vestedAt(id, t1);
        uint256 v2 = _vestedAt(id, t2);
        assertLe(v1, amount);
        assertLe(v2, amount);
        assertGe(v2, v1);
    }

    /// Random release checkpoints always pay out exactly `total` in the end.
    function testFuzz_ReleasesSumToTotal(uint256 amount, uint64 duration, uint32[4] memory steps) public {
        amount = bound(amount, 1, 10 * TOTAL);
        duration = uint64(bound(duration, 1, 365 days));

        vm.prank(owner);
        uint256 id = vault.createSchedule(alice, amount, START, 0, duration, false);

        uint256 t = START;
        for (uint256 i; i < steps.length; ++i) {
            t += bound(steps[i], 0, duration);
            vm.warp(t);
            if (vault.releasable(id) > 0) vault.release(id);
        }
        vm.warp(uint256(START) + duration);
        if (vault.releasable(id) > 0) vault.release(id);

        assertEq(token.balanceOf(alice), amount);
        assertEq(vault.totalAllocated(), 0);
    }

    /// After revoke at a random time, owner refund + beneficiary payout == total.
    function testFuzz_RevokeSplitsExactly(uint256 amount, uint32 revokeAfter) public {
        amount = bound(amount, 1, 10 * TOTAL);
        uint256 id = _create(alice, amount, true);

        vm.warp(uint256(START) + bound(revokeAfter, 0, 2 * DURATION));
        vm.prank(owner);
        vault.revoke(id);

        vm.warp(START + 100 * DURATION);
        if (vault.releasable(id) > 0) vault.release(id);

        assertEq(token.balanceOf(alice) + token.balanceOf(owner), amount);
        assertEq(vault.totalAllocated(), 0);
    }
}
