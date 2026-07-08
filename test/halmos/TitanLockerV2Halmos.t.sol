// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerV2 } from "../../contracts/TitanLockerV2.sol";
import { ITitanLockerManagerV2 } from "../../contracts/ITitanLockerManagerV2.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Halmos symbolic tests for TitanLockerV2 (deployed directly with a
/// placeholder manager, mirroring the V1 child Halmos setup). Covers the
/// unlock-time gate and owner-only access control that guard custody and fee
/// collection, proven over the full symbolic domain.
contract TitanLockerV2HalmosTest is Test {
  address internal constant DUMMY_MANAGER = address(0xBEEF);

  TestERC20 internal token;
  address internal owner = address(this);

  function setUp() public {
    token = new TestERC20("Halmos Token", "HLM", 1_000_000_000);
  }

  function _newErc20Locker(uint40 unlockTime) internal returns (TitanLockerV2) {
    return new TitanLockerV2(
      DUMMY_MANAGER, 0, owner, ITitanLockerManagerV2.LockKind.ERC20, address(token), 0, unlockTime
    );
  }

  /// @dev For ANY (unlockTime, currentTime) with currentTime < unlockTime,
  /// withdraw() always reverts with LockStillActive - no timestamp lets the
  /// asset out early.
  function check_withdrawBeforeUnlockAlwaysReverts(uint40 unlockTime, uint40 currentTime) public {
    vm.assume(currentTime < unlockTime);
    vm.warp(currentTime);
    TitanLockerV2 locker = _newErc20Locker(unlockTime);

    try locker.withdraw() {
      assertTrue(false, "withdraw() must revert before unlockTime");
    } catch (bytes memory reason) {
      assertEq(
        reason,
        abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, unlockTime),
        "must revert with LockStillActive(unlockTime)"
      );
    }
  }

  /// @dev For ANY non-owner caller, withdraw() always reverts with
  /// CallerNotOwner - proven over the whole address space.
  function check_onlyOwnerGatesWithdraw(address caller, uint40 futureOffset) public {
    vm.assume(caller != owner);
    vm.assume(futureOffset > 0);
    TitanLockerV2 locker = _newErc20Locker(uint40(block.timestamp) + futureOffset);

    vm.prank(caller);
    try locker.withdraw() {
      assertTrue(false, "withdraw() must revert for a non-owner caller");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller), "CallerNotOwner(caller)");
    }
  }

  /// @dev The onlyOwner gate runs before the kind check on collectFees, so for
  /// ANY non-owner caller collectFees always reverts with CallerNotOwner - no
  /// non-owner can ever pull a lock's fees, whatever its kind.
  function check_onlyOwnerGatesCollectFees(address caller, uint40 futureOffset) public {
    vm.assume(caller != owner);
    vm.assume(futureOffset > 0);
    TitanLockerV2 locker = _newErc20Locker(uint40(block.timestamp) + futureOffset);

    vm.prank(caller);
    try locker.collectFees() {
      assertTrue(false, "collectFees() must revert for a non-owner caller");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller), "CallerNotOwner(caller)");
    }
  }
}
