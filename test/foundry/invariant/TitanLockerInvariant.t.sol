// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { TitanLockerManagerV1 } from "../../../contracts/TitanLockerManagerV1.sol";
import { Handler } from "../handlers/Handler.sol";

/// @notice Invariant campaign driving long, randomized sequences of
/// createTokenLocker / deposit / withdraw / fee-setter calls (via the Handler)
/// against a single manager + a set of lockers it spawns, then checking
/// properties that must hold no matter what order or how many of those calls
/// happened.
contract TokenLockerInvariantTest is StdInvariant, Test {
  uint16 internal constant BPS_DENOMINATOR = 10000;

  TitanLockerManagerV1 internal manager;
  Handler internal handler;
  address internal feeReceiver;

  function setUp() public {
    feeReceiver = makeAddr("feeReceiver");
    manager = new TitanLockerManagerV1(payable(feeReceiver));

    handler = new Handler(manager);
    // let the handler drive owner-gated fee config as part of the fuzzed
    // call sequence
    manager.transferOwnership(address(handler));

    bytes4[] memory selectors = new bytes4[](7);
    selectors[0] = Handler.createLocker.selector;
    selectors[1] = Handler.depositMore.selector;
    selectors[2] = Handler.withdrawLocker.selector;
    selectors[3] = Handler.setTokenFeeBps.selector;
    selectors[4] = Handler.setEthFee.selector;
    selectors[5] = Handler.setCreationEnabled.selector;
    selectors[6] = Handler.setFeeExempt.selector;

    targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    targetContract(address(handler));
  }

  /// @dev No matter what sequence of createTokenLocker/deposit/withdraw/
  /// fee-setter calls happens, the manager's tokenFeeBps can never be observed
  /// above BPS_DENOMINATOR (10000 = 100%). setTokenFeeBps is the only setter
  /// for it and explicitly reverts above the cap - this invariant is the
  /// stateful guarantee that no call sequence (including the constructor's
  /// initial value) ever leaves the manager violating its own documented cap.
  function invariant_tokenFeeBpsNeverExceedsCap() public view {
    assertLe(manager.tokenFeeBps(), BPS_DENOMINATOR);
  }

  /// @dev createTokenLocker() always forwards the locked amount straight to a
  /// freshly deployed TitanLockerV1, and the fee straight to feeReceiver - the
  /// manager contract itself is never meant to be a custodian of the locked
  /// token, no matter how many creates/deposits/withdraws/fee changes ran
  /// before it.
  function invariant_managerNeverHoldsLockedToken() public view {
    assertEq(handler.token().balanceOf(address(manager)), 0);
  }

  /// @dev Core custody invariant: for every locker the handler has ever
  /// created, the ghost-tracked "amount that should be locked" (built purely
  /// from the effects of successful deposit()/withdraw() calls) must equal
  /// the token's actual on-chain balance held by that locker. This would
  /// catch e.g. a fee being double-charged, a deposit not being reflected, or
  /// withdraw() failing to zero out the balance.
  function invariant_lockerBalancesMatchGhostAccounting() public view {
    uint256 count = handler.createdLockerCount();
    for (uint256 i = 0; i < count; i++) {
      address lockerAddress = handler.createdLockers(i);
      assertEq(
        handler.token().balanceOf(lockerAddress),
        handler.lockerNetLocked(lockerAddress),
        "locker token balance diverged from ghost accounting"
      );
    }
  }
}
