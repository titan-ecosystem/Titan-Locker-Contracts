// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerManagerV1 } from "../../contracts/TitanLockerManagerV1.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Fuzz tests for TitanLockerManagerV1: the fee-collection math (flat
/// ETH vs token-percentage), the fee-config setters' bounds, fee exemption,
/// and the onlyOwner gate on every fee setter.
contract TitanLockerManagerV1FuzzTest is Test {
  uint16 internal constant BPS_DENOMINATOR = 10000;

  TitanLockerManagerV1 internal manager;
  TestERC20 internal token;
  address internal feeReceiver;
  address internal owner = address(this);

  function setUp() public {
    feeReceiver = makeAddr("feeReceiver");
    manager = new TitanLockerManagerV1(payable(feeReceiver));
    token = new TestERC20("Fuzz Token", "FUZZ", 1_000_000_000);
  }

  function _latestLockerAddress() internal view returns (address) {
    uint40 id = manager.tokenLockerCount() - 1;
    return manager.getTokenLockAddress(id);
  }

  /// @dev Core fee-math property: on the token-percentage path (msg.value ==
  /// 0), the amount that actually reaches the locker (amountToLock) can never
  /// exceed the amount the caller asked to lock, for any fuzzed amount and any
  /// fuzzed-but-in-range tokenFeeBps (bounded to the contract's own valid
  /// [0, 10000] domain). It must also match the exact fee formula, with the
  /// difference paid to feeReceiver.
  function testFuzz_TokenFeePathNeverLocksMoreThanDeposited(uint256 amount, uint16 bps, uint40 futureOffset) public {
    amount = bound(amount, 1, token.totalSupply());
    bps = uint16(bound(bps, 0, BPS_DENOMINATOR));
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 5));
    uint40 unlockTime = uint40(block.timestamp) + futureOffset;

    manager.setTokenFeeBps(bps);

    token.approve(address(manager), amount);
    manager.createTokenLocker(address(token), amount, unlockTime);

    address lockerAddress = _latestLockerAddress();
    uint256 amountToLock = token.balanceOf(lockerAddress);

    assertLe(amountToLock, amount, "amountToLock must never exceed the requested amount");

    uint256 expectedFee = (amount * bps) / BPS_DENOMINATOR;
    assertEq(amountToLock, amount - expectedFee, "amountToLock must equal amount minus the bps fee");
    assertEq(token.balanceOf(feeReceiver), expectedFee, "feeReceiver must receive exactly the bps fee");
  }

  /// @dev On the flat-ETH path (msg.value == ethFee()), 100% of the deposited
  /// token amount is locked - the fee is paid entirely out-of-band in ETH, for
  /// any fuzzed amount.
  function testFuzz_EthFeePathLocksFullAmount(uint256 amount, uint40 futureOffset) public {
    amount = bound(amount, 1, token.totalSupply());
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 5));
    uint40 unlockTime = uint40(block.timestamp) + futureOffset;

    uint256 fee = manager.ethFee();
    vm.deal(address(this), fee);

    token.approve(address(manager), amount);
    manager.createTokenLocker{ value: fee }(address(token), amount, unlockTime);

    address lockerAddress = _latestLockerAddress();

    assertEq(token.balanceOf(lockerAddress), amount, "flat ETH fee path must lock 100% of amount");
    assertEq(feeReceiver.balance, fee, "feeReceiver must receive the flat ETH fee");
  }

  /// @dev setTokenFeeBps enforces its documented 100% cap: any fuzzed value
  /// above BPS_DENOMINATOR (10000) must revert with TokenFeeTooHigh, and the
  /// stored value must remain unaffected.
  function testFuzz_SetTokenFeeBpsRevertsAboveCap(uint16 bps) public {
    bps = uint16(bound(bps, uint256(BPS_DENOMINATOR) + 1, type(uint16).max));
    uint16 before = manager.tokenFeeBps();

    vm.expectRevert(TitanLockerManagerV1.TokenFeeTooHigh.selector);
    manager.setTokenFeeBps(bps);

    assertEq(manager.tokenFeeBps(), before, "a reverted setter must not change state");
  }

  /// @dev Conversely, any fuzzed value within the documented [0, 10000] range
  /// is always accepted and stored verbatim - the cap is not off-by-one in
  /// either direction.
  function testFuzz_SetTokenFeeBpsAcceptsValidRange(uint16 bps) public {
    bps = uint16(bound(bps, 0, BPS_DENOMINATOR));
    manager.setTokenFeeBps(bps);
    assertEq(manager.tokenFeeBps(), bps);
  }

  /// @dev Every owner-gated fee/config setter on the manager reverts with
  /// CallerNotOwner for any fuzzed non-owner caller, and never mutates state.
  function testFuzz_OnlyOwnerGatesFeeSetters(address caller, uint256 ethFeeSeed, uint16 bpsSeed) public {
    vm.assume(caller != owner);
    vm.assume(caller != address(0));

    uint256 ethFeeValue = bound(ethFeeSeed, 0, 100 ether);
    uint16 bps = uint16(bound(bpsSeed, 0, BPS_DENOMINATOR));

    uint256 ethFeeBefore = manager.ethFee();
    uint16 bpsBefore = manager.tokenFeeBps();
    address feeReceiverBefore = manager.feeReceiver();
    bool creationEnabledBefore = manager.creationEnabled();

    vm.startPrank(caller);

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    manager.setEthFee(ethFeeValue);

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    manager.setTokenFeeBps(bps);

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    manager.setFeeReceiver(payable(caller));

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    manager.setFeeExempt(caller, true);

    vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller));
    manager.setCreationEnabled(false);

    vm.stopPrank();

    assertEq(manager.ethFee(), ethFeeBefore);
    assertEq(manager.tokenFeeBps(), bpsBefore);
    assertEq(manager.feeReceiver(), feeReceiverBefore);
    assertEq(manager.creationEnabled(), creationEnabledBefore);
  }

  /// @dev A fee-exempt account always gets 100% of its amount locked and pays
  /// no token fee at all, regardless of the fuzzed amount or the currently
  /// configured tokenFeeBps - exemption always wins over the percentage path.
  function testFuzz_FeeExemptAccountPaysNoFee(uint256 amount, uint40 futureOffset, uint16 bps) public {
    amount = bound(amount, 1, token.totalSupply());
    futureOffset = uint40(bound(futureOffset, 1, 365 days * 5));
    bps = uint16(bound(bps, 0, BPS_DENOMINATOR));
    uint40 unlockTime = uint40(block.timestamp) + futureOffset;

    manager.setTokenFeeBps(bps);
    manager.setFeeExempt(owner, true);

    token.approve(address(manager), amount);
    manager.createTokenLocker(address(token), amount, unlockTime);

    address lockerAddress = _latestLockerAddress();

    assertEq(token.balanceOf(lockerAddress), amount, "exempt caller must lock 100% of amount");
    assertEq(token.balanceOf(feeReceiver), 0, "exempt caller must pay no fee");
  }
}
