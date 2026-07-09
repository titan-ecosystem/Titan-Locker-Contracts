// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerV2 } from "../../contracts/TitanLockerV2.sol";
import { ITitanLockerManagerV2 } from "../../contracts/ITitanLockerManagerV2.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";

/// @notice Fuzz tests for the vesting schedule math and release accounting.
/// The lock is deployed directly with a placeholder manager (it only calls back
/// into the manager on ownership transfer, which these tests don't exercise).
contract TitanLockerVestingFuzzTest is Test {
  address internal constant DUMMY_MANAGER = address(0xBEEF);

  TestERC20 internal token;
  address internal owner = address(this);

  function setUp() public {
    token = new TestERC20("Vest", "VEST", 1_000_000_000);
  }

  function _newVesting(uint256 total, uint40 start, uint40 cliff, uint40 end) internal returns (TitanLockerV2) {
    return new TitanLockerV2(
      DUMMY_MANAGER, 0, owner, ITitanLockerManagerV2.LockKind.ERC20_VESTING,
      address(token), 0, end, start, cliff, end, total
    );
  }

  struct Sched { uint256 total; uint40 start; uint40 cliff; uint40 end; }

  function _bound(uint256 total, uint40 start, uint256 windowSeed, uint40 cliff) internal view returns (Sched memory s) {
    s.start = uint40(bound(start, 1, 1_000_000));
    uint40 window = uint40(bound(windowSeed, 1, 1_000_000));
    s.end = s.start + window;
    s.cliff = uint40(bound(cliff, s.start, s.end));
    s.total = bound(total, 1, token.totalSupply());
  }

  /// @dev vestedAmount is always within [0, total], is 0 before the cliff, and
  /// equals total at/after end - for any schedule and any observation time.
  function testFuzz_VestedWithinBounds(
    uint256 total, uint40 start, uint256 windowSeed, uint40 cliff, uint40 t
  ) public {
    Sched memory s = _bound(total, start, windowSeed, cliff);
    vm.warp(1);
    TitanLockerV2 v = _newVesting(s.total, s.start, s.cliff, s.end);

    uint40 when = uint40(bound(t, 1, uint256(s.end) + 1_000_000));
    vm.warp(when);
    uint256 vested = v.vestedAmount();

    assertLe(vested, s.total, "vested <= total");
    if (when < s.cliff) assertEq(vested, 0, "nothing before cliff");
    if (when >= s.end) assertEq(vested, s.total, "everything at/after end");
  }

  /// @dev vestedAmount never decreases as time advances.
  function testFuzz_VestedMonotonic(
    uint256 total, uint40 start, uint256 windowSeed, uint40 cliff, uint40 t1, uint40 t2
  ) public {
    Sched memory s = _bound(total, start, windowSeed, cliff);
    vm.warp(1);
    TitanLockerV2 v = _newVesting(s.total, s.start, s.cliff, s.end);

    uint40 a = uint40(bound(t1, 1, uint256(s.end) + 1_000_000));
    uint40 b = uint40(bound(t2, a, uint256(s.end) + 1_000_000));

    vm.warp(a);
    uint256 va = v.vestedAmount();
    vm.warp(b);
    uint256 vb = v.vestedAmount();
    assertGe(vb, va, "vested is monotonic non-decreasing");
  }

  /// @dev Across a sequence of releases at increasing times, the cumulative
  /// amount released never exceeds the grant, and equals the grant once fully
  /// vested. This is the core "can't over-release" safety property.
  function testFuzz_ReleaseNeverExceedsGrant(
    uint256 total, uint40 start, uint256 windowSeed, uint40 cliff, uint40 t1, uint40 t2
  ) public {
    Sched memory s = _bound(total, start, windowSeed, cliff);
    vm.warp(1);
    TitanLockerV2 v = _newVesting(s.total, s.start, s.cliff, s.end);
    token.transfer(address(v), s.total); // fund the grant

    uint40 a = uint40(bound(t1, 1, s.end));
    uint40 b = uint40(bound(t2, a, s.end));

    uint256 before = token.balanceOf(owner);
    vm.warp(a);
    v.release();
    vm.warp(b);
    v.release();
    vm.warp(uint256(s.end) + 1);
    v.release(); // fully vested now

    uint256 releasedTotal = token.balanceOf(owner) - before;
    assertEq(releasedTotal, s.total, "fully vested releases exactly the grant");
    assertEq(v.releasedAmount(), s.total, "released bookkeeping matches");
  }
}
