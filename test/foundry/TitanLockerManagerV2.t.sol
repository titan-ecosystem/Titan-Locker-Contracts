// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerManagerV2 } from "../../contracts/TitanLockerManagerV2.sol";
import { TitanLockerV2 } from "../../contracts/TitanLockerV2.sol";
import { ITitanLockerManagerV2 } from "../../contracts/ITitanLockerManagerV2.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { MockNonfungiblePositionManagerV3 } from "../../contracts/test/MockNonfungiblePositionManagerV3.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Fuzz tests for TitanLockerManagerV2: ERC20 fee-math parity with V1,
/// the position-manager allowlist gate, position-lock custody, and the
/// per-lock fee-claim isolation guarantee (the anti-rug property).
contract TitanLockerManagerV2FuzzTest is Test {
  uint16 internal constant BPS_DENOMINATOR = 10000;
  uint16 internal constant MAX_TOKEN_FEE_BPS = 500;

  TitanLockerManagerV2 internal manager;
  TestERC20 internal token;
  MockNonfungiblePositionManagerV3 internal npm;
  TestERC20 internal t0;
  TestERC20 internal t1;
  address internal feeReceiver;
  address internal owner = address(this);

  function setUp() public {
    feeReceiver = makeAddr("feeReceiver");
    manager = new TitanLockerManagerV2(payable(feeReceiver));
    token = new TestERC20("Fuzz Token", "FUZZ", 1_000_000_000);
    npm = new MockNonfungiblePositionManagerV3();
    t0 = new TestERC20("T0", "T0", 1_000_000_000);
    t1 = new TestERC20("T1", "T1", 1_000_000_000);
    manager.setPositionManager(address(npm), ITitanLockerManagerV2.LockKind.UNIV3, true);
    npm.setApprovalForAll(address(manager), true);
  }

  function _latestLocker() internal view returns (TitanLockerV2) {
    uint40 id = manager.tokenLockerCount() - 1;
    return TitanLockerV2(payable(manager.getTokenLockAddress(id)));
  }

  // --- ERC20 fee-math parity with V1 ---

  function testFuzz_TokenFeePathNeverLocksMoreThanDeposited(uint256 amount, uint16 bps, uint40 futureOffset) public {
    amount = bound(amount, 1, token.totalSupply());
    bps = uint16(bound(bps, 0, MAX_TOKEN_FEE_BPS));
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 5));
    uint40 unlockTime = uint40(block.timestamp) + futureOffset;

    manager.setTokenFeeBps(bps);
    token.approve(address(manager), amount);
    manager.createTokenLock(address(token), amount, unlockTime, bps);

    uint256 amountToLock = token.balanceOf(address(_latestLocker()));
    uint256 expectedFee = (amount * bps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
    assertLe(amountToLock, amount, "must never lock more than deposited");
    assertEq(amountToLock, amount - expectedFee, "amountToLock == amount - fee");
    assertEq(token.balanceOf(feeReceiver), expectedFee, "feeReceiver gets the fee");
  }

  // --- position-manager allowlist ---

  function testFuzz_PositionLockRequiresAllowlistedManager(uint40 futureOffset) public {
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 5));
    MockNonfungiblePositionManagerV3 rogue = new MockNonfungiblePositionManagerV3();
    rogue.mint(address(this), address(t0), address(t1), 0, 0);
    rogue.setApprovalForAll(address(manager), true);

    uint256 fee = manager.ethFee();
    vm.deal(address(this), fee);
    vm.expectRevert(
      abi.encodeWithSelector(TitanLockerManagerV2.PositionManagerNotAllowed.selector, address(rogue))
    );
    manager.createPositionLock{ value: fee }(address(rogue), 0, uint40(block.timestamp) + futureOffset);
  }

  function testFuzz_OnlyOwnerGatesSetPositionManager(address caller) public {
    vm.assume(caller != owner && caller != address(0));
    vm.prank(caller);
    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    manager.setPositionManager(address(npm), ITitanLockerManagerV2.LockKind.UNIV3, true);
  }

  // --- position-lock custody ---

  function testFuzz_PositionLockTakesCustodyOfNft(uint40 futureOffset) public {
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 5));
    uint256 tokenId = npm.mint(address(this), address(t0), address(t1), 0, 0);

    uint256 fee = manager.ethFee();
    vm.deal(address(this), fee);
    manager.createPositionLock{ value: fee }(address(npm), tokenId, uint40(block.timestamp) + futureOffset);

    assertEq(npm.ownerOf(tokenId), address(_latestLocker()), "locker holds the NFT");
  }

  // --- fee-claim isolation (anti-rug) ---

  /// @dev Collecting fees from one lock moves exactly that lock's own position
  /// fees and nothing else: a second lock's fees are untouched, a re-collect
  /// yields zero, and a non-owner can never collect. Fuzzed over the owed
  /// amounts of both positions.
  function testFuzz_FeeClaimIsolation(uint256 a0, uint256 a1, uint256 b0, uint256 b1, address stranger) public {
    vm.assume(stranger != address(this) && stranger != address(0));
    // keep the four owed amounts within the funding token's supply
    uint256 cap = token.totalSupply() / 4;
    a0 = bound(a0, 0, cap);
    a1 = bound(a1, 0, cap);
    b0 = bound(b0, 0, cap);
    b1 = bound(b1, 0, cap);

    uint256 idA = npm.mint(address(this), address(t0), address(t1), uint128(a0), uint128(a1));
    uint256 idB = npm.mint(address(this), address(t0), address(t1), uint128(b0), uint128(b1));
    // fund the position manager so it can pay every owed unit
    t0.transfer(address(npm), uint256(a0) + b0);
    t1.transfer(address(npm), uint256(a1) + b1);

    uint256 fee = manager.ethFee();
    vm.deal(address(this), fee * 2);
    manager.createPositionLock{ value: fee }(address(npm), idA, uint40(block.timestamp) + 1 days);
    TitanLockerV2 lockerA = _latestLocker();
    manager.createPositionLock{ value: fee }(address(npm), idB, uint40(block.timestamp) + 1 days);
    TitanLockerV2 lockerB = _latestLocker();

    // a stranger cannot collect either lock
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, stranger));
    lockerA.collectFees();

    // collecting A pays exactly A's owed and leaves B fully intact
    uint256 before0 = t0.balanceOf(address(this));
    uint256 before1 = t1.balanceOf(address(this));
    lockerA.collectFees();
    assertEq(t0.balanceOf(address(this)) - before0, a0, "lock A pays exactly a0");
    assertEq(t1.balanceOf(address(this)) - before1, a1, "lock A pays exactly a1");

    // re-collecting A now yields zero (its fees are already drained)
    before0 = t0.balanceOf(address(this));
    lockerA.collectFees();
    assertEq(t0.balanceOf(address(this)) - before0, 0, "re-collect yields nothing");

    // B is untouched by A's collects
    before0 = t0.balanceOf(address(this));
    before1 = t1.balanceOf(address(this));
    lockerB.collectFees();
    assertEq(t0.balanceOf(address(this)) - before0, b0, "lock B still pays exactly b0");
    assertEq(t1.balanceOf(address(this)) - before1, b1, "lock B still pays exactly b1");
  }
}
