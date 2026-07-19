// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerManagerV2 } from "../../../contracts/TitanLockerManagerV2.sol";
import { TitanLockerV2 } from "../../../contracts/TitanLockerV2.sol";
import { ITitanLockerManagerV2 } from "../../../contracts/ITitanLockerManagerV2.sol";
import { TestERC20 } from "../../../contracts/test/TestERC20.sol";
import { MockNonfungiblePositionManagerV3 } from "../../../contracts/test/MockNonfungiblePositionManagerV3.sol";

/// @notice Fuzzed-call handler for the TitanLockerManagerV2 invariant campaign.
///
/// The handler is the manager's owner and the owner of every lock it creates -
/// both ERC20 locks and Uniswap-V3 position locks. It keeps ghost bookkeeping
/// for two properties the invariant test cross-checks after arbitrary call
/// sequences: (1) each ERC20 lock's real balance equals what was deposited into
/// it, and (2) the fees ever collected from a given position lock never exceed
/// the fees that position was ever owed - the per-lock isolation / anti-rug
/// guarantee. The mock position manager is deliberately over-funded so the only
/// thing bounding a payout is the contract logic, not the mock's balance.
contract HandlerV2 is Test {
  uint16 private constant BPS_DENOMINATOR = 10000;

  TitanLockerManagerV2 public immutable manager;
  TestERC20 public immutable token; // ERC20-lock principal
  MockNonfungiblePositionManagerV3 public immutable npm;
  TestERC20 public immutable t0; // position fee token 0
  TestERC20 public immutable t1; // position fee token 1

  address[] public erc20Lockers;
  mapping(address => uint256) public lockerNetLocked;
  mapping(address => uint40) public lockerUnlockTime;

  address[] public positionLockers;
  mapping(address => uint256) public lockerTokenId;
  mapping(address => bool) public lockerWithdrawn;
  mapping(address => uint256) public mintedOwed0;
  mapping(address => uint256) public mintedOwed1;
  mapping(address => uint256) public collected0;
  mapping(address => uint256) public collected1;

  address[] public vestingLockers;
  mapping(address => uint256) public vestingGrant;
  mapping(address => uint256) public vestingReleased;

  constructor(TitanLockerManagerV2 manager_) {
    manager = manager_;
    token = new TestERC20("Handler Token", "HTKN", 1_000_000_000);
    t0 = new TestERC20("Fee0", "FEE0", 1_000_000_000);
    t1 = new TestERC20("Fee1", "FEE1", 1_000_000_000);
    npm = new MockNonfungiblePositionManagerV3();

    // over-fund the mock so payouts are bounded by contract logic, not balance
    t0.transfer(address(npm), t0.balanceOf(address(this)) / 2);
    t1.transfer(address(npm), t1.balanceOf(address(this)) / 2);
    npm.setApprovalForAll(address(manager), true);
    // NOTE: allowlisting the npm requires manager ownership, which the handler
    // is granted after construction - the invariant test's setUp does it.

    vm.deal(address(this), 1_000_000 ether);
  }

  function erc20LockerCount() external view returns (uint256) {
    return erc20Lockers.length;
  }

  function positionLockerCount() external view returns (uint256) {
    return positionLockers.length;
  }

  function vestingLockerCount() external view returns (uint256) {
    return vestingLockers.length;
  }

  // --- vesting locks ---

  function createVestingLocker(uint256 amountSeed, uint256 windowSeed) external {
    uint256 balance = token.balanceOf(address(this));
    if (balance == 0) return;
    uint256 amount = bound(amountSeed, 1, balance);
    uint40 start = uint40(block.timestamp);
    uint40 end = start + uint40(bound(windowSeed, 1, 365 days));

    token.approve(address(manager), amount);
    uint256 fee = manager.ethFee();
    if (fee > address(this).balance) return;

    try manager.createVestingLock{ value: fee }(address(token), amount, start, start, end, 10000) {
      address l = manager.getTokenLockAddress(manager.tokenLockerCount() - 1);
      vestingLockers.push(l);
      vestingGrant[l] = token.balanceOf(l); // actual grant that landed in the lock
    } catch {}
  }

  function releaseVesting(uint256 lockerSeed, uint256 warpSeed) external {
    if (vestingLockers.length == 0) return;
    address l = vestingLockers[bound(lockerSeed, 0, vestingLockers.length - 1)];
    uint256 warp = bound(warpSeed, 0, 30 days);
    if (warp > 0) vm.warp(block.timestamp + warp);

    uint256 before = token.balanceOf(address(this));
    try TitanLockerV2(payable(l)).release() {
      vestingReleased[l] += token.balanceOf(address(this)) - before;
    } catch {}
  }

  // --- ERC20 locks ---

  function createErc20Locker(uint256 amountSeed, uint40 durationSeed, bool payWithEth) external {
    uint256 balance = token.balanceOf(address(this));
    if (balance == 0) return;
    uint256 amount = bound(amountSeed, 1, balance);
    uint40 unlockTime = uint40(block.timestamp) + uint40(bound(durationSeed, 1, 365 days * 5));

    token.approve(address(manager), amount);
    uint256 fee = manager.ethFee();
    uint256 valueToSend = payWithEth ? fee : 0;
    if (valueToSend > address(this).balance) valueToSend = 0;

    try manager.createTokenLock{ value: valueToSend }(address(token), amount, unlockTime, 10000) {
      address l = manager.getTokenLockAddress(manager.tokenLockerCount() - 1);
      erc20Lockers.push(l);
      lockerNetLocked[l] = token.balanceOf(l);
      lockerUnlockTime[l] = unlockTime;
    } catch {}
  }

  function depositMore(uint256 lockerSeed, uint256 amountSeed) external {
    if (erc20Lockers.length == 0) return;
    address l = erc20Lockers[bound(lockerSeed, 0, erc20Lockers.length - 1)];
    uint256 balance = token.balanceOf(address(this));
    uint256 amount = balance == 0 ? 0 : bound(amountSeed, 0, balance);
    if (amount > 0) token.approve(l, amount);

    try TitanLockerV2(payable(l)).deposit(amount, 0) {
      if (amount > 0) lockerNetLocked[l] += amount;
    } catch {}
  }

  function withdrawErc20(uint256 lockerSeed, bool warp) external {
    if (erc20Lockers.length == 0) return;
    address l = erc20Lockers[bound(lockerSeed, 0, erc20Lockers.length - 1)];
    if (warp && lockerUnlockTime[l] > block.timestamp) vm.warp(lockerUnlockTime[l]);

    try TitanLockerV2(payable(l)).withdraw() {
      lockerNetLocked[l] = 0;
    } catch {}
  }

  // --- V3 position locks ---

  function createPositionLocker(uint256 owed0Seed, uint256 owed1Seed, uint40 durationSeed) external {
    uint256 owed0 = bound(owed0Seed, 0, 1_000_000 ether);
    uint256 owed1 = bound(owed1Seed, 0, 1_000_000 ether);
    uint40 unlockTime = uint40(block.timestamp) + uint40(bound(durationSeed, 1, 365 days * 5));

    uint256 tokenId = npm.mint(address(this), address(t0), address(t1), uint128(owed0), uint128(owed1));
    uint256 fee = manager.ethFee();
    if (fee > address(this).balance) return;

    try manager.createPositionLock{ value: fee }(address(npm), tokenId, unlockTime) {
      address l = manager.getTokenLockAddress(manager.tokenLockerCount() - 1);
      positionLockers.push(l);
      lockerTokenId[l] = tokenId;
      lockerUnlockTime[l] = unlockTime;
      mintedOwed0[l] = owed0;
      mintedOwed1[l] = owed1;
    } catch {}
  }

  function reaccrueFees(uint256 lockerSeed, uint256 owed0Seed, uint256 owed1Seed) external {
    if (positionLockers.length == 0) return;
    address l = positionLockers[bound(lockerSeed, 0, positionLockers.length - 1)];
    if (lockerWithdrawn[l]) return;
    uint256 owed0 = bound(owed0Seed, 0, 1_000_000 ether);
    uint256 owed1 = bound(owed1Seed, 0, 1_000_000 ether);
    npm.setOwed(lockerTokenId[l], uint128(owed0), uint128(owed1));
    mintedOwed0[l] += owed0;
    mintedOwed1[l] += owed1;
  }

  function collectPositionFees(uint256 lockerSeed) external {
    if (positionLockers.length == 0) return;
    address l = positionLockers[bound(lockerSeed, 0, positionLockers.length - 1)];

    uint256 before0 = t0.balanceOf(address(this));
    uint256 before1 = t1.balanceOf(address(this));
    try TitanLockerV2(payable(l)).collectFees() {
      collected0[l] += t0.balanceOf(address(this)) - before0;
      collected1[l] += t1.balanceOf(address(this)) - before1;
    } catch {}
  }

  function withdrawPosition(uint256 lockerSeed, bool warp) external {
    if (positionLockers.length == 0) return;
    address l = positionLockers[bound(lockerSeed, 0, positionLockers.length - 1)];
    if (warp && lockerUnlockTime[l] > block.timestamp) vm.warp(lockerUnlockTime[l]);

    try TitanLockerV2(payable(l)).withdraw() {
      lockerWithdrawn[l] = true;
    } catch {}
  }

  // --- fee config ---

  function setTokenFeeBps(uint256 bpsSeed) external {
    uint16 bps = uint16(bound(bpsSeed, 0, uint256(BPS_DENOMINATOR) + 5000));
    try manager.setTokenFeeBps(bps) {} catch {}
  }

  function setEthFee(uint256 feeSeed) external {
    try manager.setEthFee(bound(feeSeed, 0, 5 ether)) {} catch {}
  }

  function setCreationEnabled(bool enabled) external {
    try manager.setCreationEnabled(enabled) {} catch {}
  }

  receive() external payable {}
}
