// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerV1 } from "../../contracts/TitanLockerV1.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Fuzz tests for TitanLockerV1 in isolation (deployed directly, not
/// through the manager - deposit/withdraw/rescue and the onlyOwner gate don't
/// depend on the manager at all; only ownership-transfer notification does,
/// which is out of scope here).
contract TitanLockerV1FuzzTest is Test {
  // TitanLockerV1 only ever calls back into `_manager` from
  // `_transferOwnership`, which none of these tests exercise, so a
  // non-contract placeholder address is fine here.
  address internal constant DUMMY_MANAGER = address(0xBEEF);

  TestERC20 internal token;
  address internal owner = address(this);

  function setUp() public {
    token = new TestERC20("Fuzz Token", "FUZZ", 1_000_000_000);
  }

  function _newLocker(uint40 unlockTime) internal returns (TitanLockerV1) {
    return new TitanLockerV1(DUMMY_MANAGER, 0, owner, address(token), unlockTime);
  }

  /// @dev Depositing any fuzzed valid amount - whether at construction-time
  /// top-up via deposit() right after deploy, or a later top-up - always
  /// results in getLockData().balance reporting exactly the tokens that were
  /// actually transferred in. TitanLockerV1 itself never takes a fee (fees are
  /// only ever collected by the manager before tokens reach the locker), so
  /// balance must track deposits 1:1.
  function testFuzz_DepositTracksExactAmount(uint256 amount, uint40 futureOffset) public {
    amount = bound(amount, 0, token.totalSupply());
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 50));
    uint40 unlockTime = uint40(block.timestamp) + futureOffset;

    TitanLockerV1 locker = _newLocker(unlockTime);

    if (amount > 0) {
      token.approve(address(locker), amount);
    }
    locker.deposit(amount, 0);

    (, , , , , , , uint40 reportedUnlock, uint256 balance, ) = locker.getLockData();
    assertEq(balance, amount, "getLockData().balance must equal amount deposited");
    assertEq(reportedUnlock, unlockTime, "unlockTime must be unchanged when newUnlockTime_ is 0");
  }

  /// @dev deposit()'s newUnlockTime_ argument can only ever move the unlock
  /// time forward - any fuzzed target strictly earlier than the current
  /// unlockTime must revert with UnlockTimeCannotBeReduced.
  function testFuzz_DepositCannotReduceUnlockTime(uint40 initialOffset, uint256 attemptedUnlockSeed) public {
    initialOffset = uint40(bound(initialOffset, 100, 365 days * 50));
    uint40 initialUnlock = uint40(block.timestamp) + initialOffset;
    TitanLockerV1 locker = _newLocker(initialUnlock);

    // any timestamp in [now, initialUnlock - 1] is strictly earlier than the
    // locker's current unlockTime and must be rejected
    uint40 attemptedUnlock = uint40(bound(attemptedUnlockSeed, block.timestamp, initialUnlock - 1));

    vm.expectRevert(TitanLockerV1.UnlockTimeCannotBeReduced.selector);
    locker.deposit(0, attemptedUnlock);
  }

  /// @dev For any fuzzed unlockTime in the future, withdraw() always reverts
  /// with LockStillActive before that time is reached.
  function testFuzz_WithdrawBeforeUnlockAlwaysReverts(uint40 futureOffset) public {
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 50));
    uint40 unlockTime = uint40(block.timestamp) + futureOffset;
    TitanLockerV1 locker = _newLocker(unlockTime);

    vm.expectRevert(abi.encodeWithSelector(TitanLockerV1.LockStillActive.selector, unlockTime));
    locker.withdraw();
  }

  /// @dev Once unlockTime has passed (fuzzed how far in the future it was and
  /// how far past it we warp to), withdraw() always succeeds, empties the
  /// locker's token balance to exactly 0, and pays the full deposited amount
  /// to the owner.
  function testFuzz_WithdrawAfterUnlockSucceeds(uint256 amount, uint40 futureOffset, uint40 pastOffset) public {
    amount = bound(amount, 1, token.totalSupply());
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 5));
    pastOffset = uint40(bound(pastOffset, 0, 365 days * 5));

    uint40 unlockTime = uint40(block.timestamp) + futureOffset;
    TitanLockerV1 locker = _newLocker(unlockTime);

    token.approve(address(locker), amount);
    locker.deposit(amount, 0);

    vm.warp(uint256(unlockTime) + pastOffset);

    uint256 ownerBalanceBefore = token.balanceOf(owner);
    locker.withdraw();

    assertEq(token.balanceOf(address(locker)), 0, "locker must be emptied");
    assertEq(token.balanceOf(owner), ownerBalanceBefore + amount, "owner must receive the full locked amount");
  }

  /// @dev Every owner-gated function on TitanLockerV1 reverts with
  /// CallerNotOwner for any fuzzed non-owner caller.
  function testFuzz_OnlyOwnerGatesDepositAndWithdraw(address caller, uint40 futureOffset) public {
    vm.assume(caller != owner);
    vm.assume(caller != address(0));

    futureOffset = uint40(bound(futureOffset, 1, 365 days * 50));
    uint40 unlockTime = uint40(block.timestamp) + futureOffset;
    TitanLockerV1 locker = _newLocker(unlockTime);

    vm.startPrank(caller);

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    locker.deposit(0, 0);

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    locker.withdraw();

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    locker.withdrawToken(address(0xdead));

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    locker.withdrawEth();

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    locker.transferOwnership(caller);

    vm.stopPrank();
  }
}
