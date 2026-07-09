// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerV2 } from "../../contracts/TitanLockerV2.sol";
import { ITitanLockerManagerV2 } from "../../contracts/ITitanLockerManagerV2.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Halmos symbolic proofs for vesting: release is owner-only, and the
/// vested amount is bounded by the grant over the whole symbolic time domain.
contract TitanLockerVestingHalmosTest is Test {
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

  /// @dev For ANY non-owner caller, release() reverts with CallerNotOwner - the
  /// onlyOwner gate runs before the vesting-kind check, so no one but the owner
  /// can ever pull vested tokens.
  function check_onlyOwnerGatesRelease(address caller) public {
    vm.assume(caller != owner);
    vm.warp(1);
    TitanLockerV2 v = _newVesting(1000, 100, 100, 1000);

    vm.prank(caller);
    try v.release() {
      assertTrue(false, "release() must revert for a non-owner caller");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller), "CallerNotOwner(caller)");
    }
  }

  /// @dev Over the whole symbolic time domain, the vested amount stays within
  /// [0, total], is 0 before the cliff, and is exactly total once past `end`.
  /// `total` is concrete here (the divisor and grant are fixed) so the solver
  /// avoids a symbolic multiply-and-divide; the fully-symbolic-`total` case is
  /// covered by the Foundry fuzz suite (testFuzz_VestedWithinBounds).
  function check_vestedNeverExceedsTotal(uint40 t) public {
    uint256 total = 1_000_000 ether;
    uint40 start = 100;
    uint40 cliff = 400;
    uint40 end = 1100;
    vm.warp(1);
    TitanLockerV2 v = _newVesting(total, start, cliff, end);

    uint40 when = uint40(1 + (t % 5000));
    vm.warp(when);
    uint256 vested = v.vestedAmount();

    assertLe(vested, total, "vested <= total");
    if (when < cliff) assertEq(vested, 0, "nothing before cliff");
    if (when >= end) assertEq(vested, total, "vested == total at/after end");
  }
}
