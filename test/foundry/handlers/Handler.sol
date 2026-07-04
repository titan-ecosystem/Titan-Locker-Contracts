// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerManagerV1 } from "../../../contracts/TitanLockerManagerV1.sol";
import { TitanLockerV1 } from "../../../contracts/TitanLockerV1.sol";
import { TestERC20 } from "../../../contracts/test/TestERC20.sol";

/// @notice Fuzzed-call handler for the TitanLockerManagerV1/TitanLockerV1
/// invariant campaign.
///
/// The handler is the sole external actor the invariant fuzzer drives: it is
/// both the manager's owner (so it can mutate fee config) and the creator/
/// owner of every TitanLockerV1 it spins up (so it can deposit/withdraw on
/// them directly, with no pranking required). It keeps its own "ghost"
/// bookkeeping of what each locker's token balance *should* be, built purely
/// from the effects of successful deposit/withdraw calls, so the invariant
/// test can cross-check that ghost accounting against real on-chain balances
/// after arbitrarily long randomized call sequences.
///
/// Every state-mutating call is wrapped in try/catch: many fuzzed inputs are
/// expected to legitimately revert (e.g. creation disabled, bps above cap,
/// withdrawing before unlockTime), and `fail_on_revert = false` means those
/// reverts don't abort the campaign - they're just no-ops for ghost state.
contract Handler is Test {
  uint16 private constant BPS_DENOMINATOR = 10000;

  TitanLockerManagerV1 public immutable manager;
  TestERC20 public immutable token;

  address[] public createdLockers;
  mapping(address => uint256) public lockerNetLocked;
  mapping(address => uint40) public lockerUnlockTime;

  uint256 public createCalls;
  uint256 public createSuccesses;
  uint256 public depositCalls;
  uint256 public depositSuccesses;
  uint256 public withdrawCalls;
  uint256 public withdrawSuccesses;

  constructor(TitanLockerManagerV1 manager_) {
    manager = manager_;
    // the handler mints its own token supply (it is msg.sender in the
    // TestERC20 constructor) so it always has funds to deposit with
    token = new TestERC20("Handler Token", "HTKN", 1_000_000_000);
    vm.deal(address(this), 1_000_000 ether);
  }

  function createdLockerCount() external view returns (uint256) {
    return createdLockers.length;
  }

  // --- fuzzed entry points, all called with msg.sender == address(this) ---

  function createLocker(uint256 amountSeed, uint40 durationSeed, bool payWithEth) external {
    createCalls++;

    uint256 balance = token.balanceOf(address(this));
    if (balance == 0) return;
    uint256 amount = bound(amountSeed, 1, balance);
    uint40 duration = uint40(bound(durationSeed, 1, 365 days * 5));
    uint40 unlockTime = uint40(block.timestamp) + duration;

    token.approve(address(manager), amount);

    uint256 fee = manager.ethFee();
    uint256 valueToSend = payWithEth ? fee : 0;
    if (valueToSend > address(this).balance) valueToSend = 0;

    try manager.createTokenLocker{ value: valueToSend }(address(token), amount, unlockTime) {
      createSuccesses++;
      uint40 id = manager.tokenLockerCount() - 1;
      address lockerAddress = manager.getTokenLockAddress(id);
      createdLockers.push(lockerAddress);
      // the locker is brand new, so its whole balance is what was actually
      // locked for this call - no need to reconstruct the fee math here
      lockerNetLocked[lockerAddress] = token.balanceOf(lockerAddress);
      lockerUnlockTime[lockerAddress] = unlockTime;
    } catch {
      // expected: creation disabled, exempt account sent ETH, wrong ETH fee, ...
    }
  }

  function depositMore(uint256 lockerSeed, uint256 amountSeed, uint40 extendSeed) external {
    depositCalls++;
    if (createdLockers.length == 0) return;

    address lockerAddress = createdLockers[bound(lockerSeed, 0, createdLockers.length - 1)];
    TitanLockerV1 locker = TitanLockerV1(payable(lockerAddress));

    uint256 balance = token.balanceOf(address(this));
    uint256 amount = balance == 0 ? 0 : bound(amountSeed, 0, balance);

    uint40 currentUnlock = lockerUnlockTime[lockerAddress];
    uint40 newUnlockTime;
    if (extendSeed % 2 == 0) {
      newUnlockTime = 0;
    } else {
      uint40 base = currentUnlock > uint40(block.timestamp) ? currentUnlock : uint40(block.timestamp);
      uint40 extension = uint40(bound(extendSeed, 1, 365 days * 5));
      newUnlockTime = base + extension;
    }

    if (amount > 0) token.approve(lockerAddress, amount);

    try locker.deposit(amount, newUnlockTime) {
      depositSuccesses++;
      if (amount > 0) lockerNetLocked[lockerAddress] += amount;
      if (newUnlockTime != 0) lockerUnlockTime[lockerAddress] = newUnlockTime;
    } catch {
      // expected: newUnlockTime_ would reduce the current unlockTime
    }
  }

  function withdrawLocker(uint256 lockerSeed, bool warpToUnlock) external {
    withdrawCalls++;
    if (createdLockers.length == 0) return;

    address lockerAddress = createdLockers[bound(lockerSeed, 0, createdLockers.length - 1)];
    TitanLockerV1 locker = TitanLockerV1(payable(lockerAddress));

    if (warpToUnlock) {
      uint40 unlockTime = lockerUnlockTime[lockerAddress];
      if (unlockTime > block.timestamp) vm.warp(unlockTime);
    }

    try locker.withdraw() {
      withdrawSuccesses++;
      lockerNetLocked[lockerAddress] = 0;
    } catch {
      // expected: unlockTime not reached yet
    }
  }

  function setTokenFeeBps(uint256 bpsSeed) external {
    // deliberately allow seeds beyond BPS_DENOMINATOR through so the
    // TokenFeeTooHigh revert path is exercised too, not just the happy path
    uint16 bps = uint16(bound(bpsSeed, 0, uint256(BPS_DENOMINATOR) + 5000));
    try manager.setTokenFeeBps(bps) {} catch {}
  }

  function setEthFee(uint256 feeSeed) external {
    uint256 fee = bound(feeSeed, 0, 5 ether);
    try manager.setEthFee(fee) {} catch {}
  }

  function setCreationEnabled(bool enabled) external {
    try manager.setCreationEnabled(enabled) {} catch {}
  }

  function setFeeExempt(bool exempt) external {
    try manager.setFeeExempt(address(this), exempt) {} catch {}
  }

  receive() external payable {}
}
