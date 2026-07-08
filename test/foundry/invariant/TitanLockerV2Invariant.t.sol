// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { TitanLockerManagerV2 } from "../../../contracts/TitanLockerManagerV2.sol";
import { TitanLockerV2 } from "../../../contracts/TitanLockerV2.sol";
import { TestERC20 } from "../../../contracts/test/TestERC20.sol";
import { MockNonfungiblePositionManagerV3 } from "../../../contracts/test/MockNonfungiblePositionManagerV3.sol";
import { ITitanLockerManagerV2 } from "../../../contracts/ITitanLockerManagerV2.sol";
import { HandlerV2 } from "../handlers/HandlerV2.sol";

/// @notice Invariant campaign for TitanLockerManagerV2. The handler drives
/// arbitrary sequences of ERC20 + V3 position lock creation, deposits, fee
/// collection, re-accrual, and withdrawals; these invariants must hold after
/// every step.
contract TitanLockerV2InvariantTest is StdInvariant, Test {
  TitanLockerManagerV2 internal manager;
  HandlerV2 internal handler;

  function setUp() public {
    address feeReceiver = makeAddr("feeReceiver");
    manager = new TitanLockerManagerV2(payable(feeReceiver));
    handler = new HandlerV2(manager);
    // allowlist the handler's mock position manager while we still own the
    // manager, then hand ownership to the handler so it can drive the campaign
    manager.setPositionManager(address(handler.npm()), ITitanLockerManagerV2.LockKind.UNIV3, true);
    manager.transferOwnership(address(handler));

    bytes4[] memory selectors = new bytes4[](9);
    selectors[0] = HandlerV2.createErc20Locker.selector;
    selectors[1] = HandlerV2.depositMore.selector;
    selectors[2] = HandlerV2.withdrawErc20.selector;
    selectors[3] = HandlerV2.createPositionLocker.selector;
    selectors[4] = HandlerV2.reaccrueFees.selector;
    selectors[5] = HandlerV2.collectPositionFees.selector;
    selectors[6] = HandlerV2.withdrawPosition.selector;
    selectors[7] = HandlerV2.setTokenFeeBps.selector;
    selectors[8] = HandlerV2.setEthFee.selector;

    targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    targetContract(address(handler));
  }

  /// @dev The manager is a pure factory - it must never hold a locked ERC20 or
  /// custody any position NFT.
  function invariant_managerHoldsNothing() public view {
    assertEq(handler.token().balanceOf(address(manager)), 0, "manager holds no principal token");
    assertEq(handler.t0().balanceOf(address(manager)), 0, "manager holds no fee token 0");
    assertEq(handler.t1().balanceOf(address(manager)), 0, "manager holds no fee token 1");
    assertEq(handler.npm().balanceOf(address(manager)), 0, "manager custodies no NFT");
  }

  /// @dev No phantom balances: each ERC20 lock's real balance equals exactly
  /// what the handler deposited into it.
  function invariant_erc20LockerBalancesMatchGhost() public view {
    TestERC20 token = handler.token();
    uint256 n = handler.erc20LockerCount();
    for (uint256 i = 0; i < n; i++) {
      address l = handler.erc20Lockers(i);
      assertEq(token.balanceOf(l), handler.lockerNetLocked(l), "erc20 lock balance == ghost");
    }
  }

  /// @dev Custody: every position lock that has not been withdrawn still holds
  /// its own NFT (it never leaks to another party).
  function invariant_positionCustody() public view {
    MockNonfungiblePositionManagerV3 npm = handler.npm();
    uint256 n = handler.positionLockerCount();
    for (uint256 i = 0; i < n; i++) {
      address l = handler.positionLockers(i);
      if (handler.lockerWithdrawn(l)) continue;
      assertEq(npm.ownerOf(handler.lockerTokenId(l)), l, "active position lock holds its NFT");
    }
  }

  /// @dev The anti-rug property: fees ever collected from a position lock can
  /// never exceed the fees that lock's own position was ever owed. If any lock
  /// could pull another lock's fees, its collected total would exceed its own
  /// minted-owed total and this would fail.
  function invariant_feeClaimIsolation() public view {
    uint256 n = handler.positionLockerCount();
    for (uint256 i = 0; i < n; i++) {
      address l = handler.positionLockers(i);
      assertLe(handler.collected0(l), handler.mintedOwed0(l), "collected0 <= owed0");
      assertLe(handler.collected1(l), handler.mintedOwed1(l), "collected1 <= owed1");
    }
  }

  /// @dev The token-fee cap can never be exceeded, whatever the call sequence.
  function invariant_tokenFeeBpsNeverExceedsCap() public view {
    assertLe(manager.tokenFeeBps(), 10000, "tokenFeeBps <= 100%");
  }
}
