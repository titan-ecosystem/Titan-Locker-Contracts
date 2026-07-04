// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerV1 } from "../../contracts/TitanLockerV1.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Halmos symbolic tests for TitanLockerV1 (deployed directly, not
/// through the manager - mirrors test/foundry/TitanLockerV1.t.sol's setup,
/// but instead of sampling fuzzed inputs, Halmos explores every input in the
/// declared symbolic domain and either proves the property for ALL of them
/// or produces a concrete counterexample).
///
/// Convention: `check_*` functions are Halmos's equivalent of Foundry's
/// `testFuzz_*` - every parameter is treated as a fully symbolic value unless
/// narrowed with `vm.assume`.
contract TitanLockerV1HalmosTest is Test {
  // TitanLockerV1 only ever calls back into `_manager` from
  // `_transferOwnership`, which none of these properties exercise, so a
  // non-contract placeholder address is fine here (same as the Foundry fuzz
  // suite's DUMMY_MANAGER).
  address internal constant DUMMY_MANAGER = address(0xBEEF);

  TestERC20 internal token;
  address internal owner = address(this);

  function setUp() public {
    token = new TestERC20("Halmos Token", "HLM", 1_000_000_000);
  }

  function _newLocker(uint40 unlockTime) internal returns (TitanLockerV1) {
    return new TitanLockerV1(DUMMY_MANAGER, 0, owner, address(token), unlockTime);
  }

  /// @dev Property: for ANY symbolic (unlockTime, currentTime) pair such that
  /// currentTime is strictly before unlockTime, withdraw() always reverts
  /// with LockStillActive - there is no timestamp anywhere in that entire
  /// symbolic space that lets funds out early. A fuzzer can only sample a
  /// finite set of (unlockTime, currentTime) pairs and would very likely
  /// never hit the exact boundary cases (e.g. currentTime == unlockTime - 1,
  /// or unlockTime == type(uint40).max); Halmos proves it for the whole
  /// domain at once, including every boundary value.
  ///
  /// currentTime doubles as the deployment-time timestamp (vm.warp'd before
  /// construction) and the withdrawal-time timestamp, since
  /// currentTime < unlockTime already satisfies the constructor's
  /// `unlockTime_ > block.timestamp` requirement.
  function check_withdrawBeforeUnlockAlwaysReverts(uint40 unlockTime, uint40 currentTime) public {
    vm.assume(currentTime < unlockTime);

    vm.warp(currentTime);
    TitanLockerV1 locker = _newLocker(unlockTime);

    // Halmos 0.3.3 does not implement vm.expectRevert (any overload) - see
    // https://github.com/a16z/halmos/wiki/Supported-Foundry-Cheatcodes. Use
    // native try/catch instead and assert on the exact revert data, which is
    // the pattern halmos's own regression suite uses for this.
    try locker.withdraw() {
      assertTrue(false, "withdraw() must revert before unlockTime");
    } catch (bytes memory reason) {
      assertEq(
        reason,
        abi.encodeWithSelector(TitanLockerV1.LockStillActive.selector, unlockTime),
        "must revert with LockStillActive(unlockTime)"
      );
    }
  }

  /// @dev Property: for ANY symbolic caller address other than the lock's
  /// owner, withdraw() always reverts with CallerNotOwner - proven for every
  /// possible address (including precompiles, the manager placeholder, the
  /// token contract itself, etc.), not just a handful of fuzzed addresses.
  function check_onlyOwnerGatesWithdraw(address caller, uint40 futureOffset) public {
    vm.assume(caller != owner);
    vm.assume(futureOffset > 0);

    uint40 unlockTime = uint40(block.timestamp) + futureOffset;
    TitanLockerV1 locker = _newLocker(unlockTime);

    vm.prank(caller);
    try locker.withdraw() {
      assertTrue(false, "withdraw() must revert for a non-owner caller");
    } catch (bytes memory reason) {
      assertEq(
        reason,
        abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller),
        "must revert with CallerNotOwner(caller)"
      );
    }
  }

  /// @dev Property: depositing any symbolic `amount` (bounded only to the
  /// token's actual supply, so every value the token could ever hold is
  /// covered) always increases the locker's reported balance by exactly
  /// `amount` - TitanLockerV1 itself never skims a fee (fees are only ever
  /// collected by the manager before tokens reach the locker).
  function check_depositTracksExactAmount(uint256 amount, uint40 futureOffset) public {
    vm.assume(futureOffset > 0);
    amount = amount % (token.totalSupply() + 1); // bound into [0, totalSupply], keeping every reachable value

    uint40 unlockTime = uint40(block.timestamp) + futureOffset;
    TitanLockerV1 locker = _newLocker(unlockTime);

    if (amount > 0) {
      token.approve(address(locker), amount);
    }
    locker.deposit(amount, 0);

    (, , , , , , , , uint256 balance, ) = locker.getLockData();
    assertEq(balance, amount, "getLockData().balance must equal amount deposited");
  }
}
