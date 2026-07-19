// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerManagerV2 } from "../../contracts/TitanLockerManagerV2.sol";
import { ITitanLockerManagerV2 } from "../../contracts/ITitanLockerManagerV2.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Halmos symbolic tests for TitanLockerManagerV2 - the ERC20 fee math
/// (parity with V1) plus the new position-manager allowlist's access control
/// and kind validation, proven over the full symbolic input domain.
contract TitanLockerManagerV2HalmosTest is Test {
  uint16 internal constant BPS_DENOMINATOR = 10000;
  uint16 internal constant MAX_TOKEN_FEE_BPS = 500;

  TitanLockerManagerV2 internal manager;
  TestERC20 internal token;
  address internal feeReceiver;
  address internal owner = address(this);

  function setUp() public {
    // concrete address, see the V1 Halmos note on symbolic-storage false positives
    feeReceiver = address(0xFEE);
    manager = new TitanLockerManagerV2(payable(feeReceiver));
    token = new TestERC20("Halmos Token", "HLM", 1_000_000_000);
  }

  function _latestLockerAddress() internal view returns (address) {
    uint40 id = manager.tokenLockerCount() - 1;
    return manager.getTokenLockAddress(id);
  }

  /// @dev Fee-math parity: on the token-percentage path, for ANY symbolic
  /// amount in [1, totalSupply] and bps in [0, 10000], the locked amount never
  /// exceeds the deposit and equals the exact fee formula.
  function check_tokenFeeNeverExceedsAmount(uint256 amount, uint16 bps) public {
    vm.assume(bps <= MAX_TOKEN_FEE_BPS);
    amount = 1 + (amount % token.totalSupply());

    manager.setTokenFeeBps(bps);
    token.approve(address(manager), amount);
    manager.createTokenLock(address(token), amount, uint40(block.timestamp) + 1, bps);

    uint256 amountToLock = token.balanceOf(_latestLockerAddress());
    assertLe(amountToLock, amount, "amountToLock must never exceed the requested amount");

    uint256 expectedFee = (amount * bps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
    assertEq(amountToLock, amount - expectedFee, "amountToLock must equal amount minus the bps fee");
    assertEq(token.balanceOf(feeReceiver), expectedFee, "feeReceiver must receive exactly the bps fee");
  }

  function check_setTokenFeeBpsRevertsAboveCap(uint16 bps) public {
    vm.assume(bps > MAX_TOKEN_FEE_BPS);
    uint16 before = manager.tokenFeeBps();

    try manager.setTokenFeeBps(bps) {
      assertTrue(false, "setTokenFeeBps must revert above the cap");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(TitanLockerManagerV2.TokenFeeTooHigh.selector), "TokenFeeTooHigh");
    }
    assertEq(manager.tokenFeeBps(), before, "a reverted setter must not change state");
  }

  function check_setTokenFeeBpsAcceptsValidRange(uint16 bps) public {
    vm.assume(bps <= MAX_TOKEN_FEE_BPS);
    manager.setTokenFeeBps(bps);
    assertEq(manager.tokenFeeBps(), bps);
  }

  /// @dev Caller-side slippage protection: for ANY symbolic live fee and ANY
  /// symbolic caller-supplied max strictly below it, createTokenLock always
  /// reverts with TokenFeeExceedsCallerMax - and, critically, nothing
  /// partially executes: no tokens move and no lock gets created. This is
  /// what protects a caller from a fee change landing between their
  /// submission and mining, independent of the protocol-wide 5% cap above.
  function check_createTokenLockRevertsAboveCallerMax(uint256 amount, uint16 bps, uint16 maxTokenFeeBps) public {
    vm.assume(maxTokenFeeBps < bps);
    vm.assume(bps <= MAX_TOKEN_FEE_BPS);
    amount = 1 + (amount % token.totalSupply());

    manager.setTokenFeeBps(bps);
    token.approve(address(manager), amount);

    uint256 balanceBefore = token.balanceOf(address(this));
    uint40 countBefore = manager.tokenLockerCount();

    try manager.createTokenLock(address(token), amount, uint40(block.timestamp) + 1, maxTokenFeeBps) {
      assertTrue(false, "createTokenLock must revert when the live fee exceeds the caller's max");
    } catch (bytes memory reason) {
      assertEq(
        reason,
        abi.encodeWithSelector(TitanLockerManagerV2.TokenFeeExceedsCallerMax.selector, bps, maxTokenFeeBps),
        "TokenFeeExceedsCallerMax(liveTokenFeeBps, maxTokenFeeBps)"
      );
    }

    assertEq(token.balanceOf(address(this)), balanceBefore, "a reverted create must not move any tokens");
    assertEq(manager.tokenLockerCount(), countBefore, "a reverted create must not create a lock");
  }

  /// @dev For ANY symbolic unlockTime, createTokenLock(amount_ = 0) always
  /// reverts with ZeroAmount and never creates a lock - closes the free,
  /// no-capital-required spam path (you don't even need to hold or approve
  /// the token, since transferFrom(0) trivially succeeds otherwise).
  function check_createTokenLockRevertsOnZeroAmount(uint40 unlockTime) public {
    vm.assume(unlockTime > block.timestamp);
    uint40 countBefore = manager.tokenLockerCount();

    try manager.createTokenLock(address(token), 0, unlockTime, type(uint16).max) {
      assertTrue(false, "createTokenLock must revert on amount_ == 0");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(TitanLockerManagerV2.ZeroAmount.selector), "ZeroAmount()");
    }

    assertEq(manager.tokenLockerCount(), countBefore, "a reverted create must not create a lock");
  }

  /// @dev Same guarantee for the vesting path: ANY symbolic (start, cliff,
  /// end) with amount_ = 0 always reverts with ZeroAmount, before the
  /// vesting-schedule validation even runs.
  function check_createVestingLockRevertsOnZeroAmount(uint40 start, uint40 cliff, uint40 end) public {
    uint40 countBefore = manager.tokenLockerCount();

    try manager.createVestingLock(address(token), 0, start, cliff, end, type(uint16).max) {
      assertTrue(false, "createVestingLock must revert on amount_ == 0");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(TitanLockerManagerV2.ZeroAmount.selector), "ZeroAmount()");
    }

    assertEq(manager.tokenLockerCount(), countBefore, "a reverted create must not create a lock");
  }

  /// @dev Access control: for ANY symbolic non-owner caller, setPositionManager
  /// always reverts with CallerNotOwner and never allowlists anything.
  function check_onlyOwnerCanSetPositionManager(address caller, address pm, bool allowed) public {
    vm.assume(caller != owner);
    vm.assume(pm != address(0));

    vm.prank(caller);
    try manager.setPositionManager(pm, ITitanLockerManagerV2.LockKind.UNIV3, allowed) {
      assertTrue(false, "setPositionManager must revert for a non-owner");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller), "CallerNotOwner(caller)");
    }

    (, bool isAllowed) = manager.positionManagerKind(pm);
    assertEq(isAllowed, false, "a reverted allowlist call must not enable the manager");
  }

  /// @dev Kind validation: allowlisting with the ERC20 kind always reverts, for
  /// any symbolic manager address - only UNIV3/UNIV4 are valid position kinds.
  function check_setPositionManagerRejectsErc20Kind(address pm) public {
    vm.assume(pm != address(0));
    try manager.setPositionManager(pm, ITitanLockerManagerV2.LockKind.ERC20, true) {
      assertTrue(false, "ERC20 kind must be rejected for a position manager");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(TitanLockerManagerV2.InvalidPositionManagerKind.selector), "InvalidKind");
    }
  }
}
