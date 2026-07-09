// SPDX-License-Identifier: GPL-3.0-or-later

/**
  ___________________    _   __   __    ____  ________ __ __________
 /_  __/  _/_  __/   |  / | / /  / /   / __ \/ ____/ //_// ____/ __ \
  / /  / /  / / / /| | /  |/ /  / /   / / / / /   / ,<  / __/ / /_/ /
 / / _/ /  / / / ___ |/ /|  /  / /___/ /_/ / /___/ /| |/ /___/ _, _/
/_/ /___/ /_/ /_/  |_/_/ |_/  /_____/\____/\____/_/ |_/_____/_/ |_|

  Locker manager / factory (V2 - tokens + V2/V3/V4 LP)
*/
pragma solidity 0.8.30;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ITitanLockerManagerV2 } from "./ITitanLockerManagerV2.sol";
import { Ownable } from "./Ownable.sol";
import { TitanLockerV2 } from "./TitanLockerV2.sol";

/// @notice Deploys and indexes `TitanLockerV2` instances for three lock kinds -
/// plain/LP ERC20 tokens, Uniswap V3 positions, and Uniswap V4 positions - all
/// through one manager. Each lock is its own child contract, so custody is
/// isolated per lock. V3/V4 positions can only be locked against a
/// position manager the owner has allowlisted, which is both the multichain
/// mechanism and the kill-switch for un-validated integrations.
contract TitanLockerManagerV2 is ITitanLockerManagerV2, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  error CreationDisabled();
  error IncorrectEthFee(uint256 expected, uint256 received);
  error ExemptAccountsPayNoEth();
  error TokenFeeTooHigh();
  error CallerIsNotLocker(uint40 id, address caller);
  error EthTransferFailed();
  error PositionManagerNotAllowed(address positionManager);
  error InvalidPositionManagerKind();
  error InvalidVestingSchedule();

  uint16 private constant BPS_DENOMINATOR = 10000;

  bool private _creationEnabled = true;
  uint40 private _tokenLockerCount;

  mapping(uint40 => TitanLockerV2) private _tokenLockers;
  /// @dev Lets the frontend search lockers by creator, locked token/position
  /// manager, locker address, or either underlying paired token.
  mapping(address => uint40[]) private _tokenLockersForAddress;

  /// @dev Allowlist of Uniswap position managers. `_pmKind` records whether a
  /// manager is V3- or V4-style; `_pmAllowed` gates whether new locks may use
  /// it. A manager with `_pmAllowed == false` is rejected regardless of kind.
  mapping(address => LockKind) private _pmKind;
  mapping(address => bool) private _pmAllowed;

  uint256 private _ethFee;
  uint16 private _tokenFeeBps;
  address payable private _feeReceiver;
  mapping(address => bool) private _feeExempt;

  constructor(address payable feeReceiver_) Ownable(_msgSender()) {
    if (feeReceiver_ == address(0)) revert ZeroAddress();
    _feeReceiver = feeReceiver_;
    // same starting fee schedule as V1; both adjustable via the setters below.
    _ethFee = 0.2 ether;
    _tokenFeeBps = 500; // 5.00%
  }

  modifier allowCreation() {
    if (!_creationEnabled) revert CreationDisabled();
    _;
  }

  // --- config ---

  function tokenLockerCount() external view override returns (uint40) {
    return _tokenLockerCount;
  }

  function creationEnabled() external view override returns (bool) {
    return _creationEnabled;
  }

  /// @dev Turns off new locks so users can be migrated to a future version.
  /// Existing locks keep working (extend/deposit/withdraw/collect) as normal.
  function setCreationEnabled(bool value_) external override onlyOwner {
    _creationEnabled = value_;
  }

  // --- position-manager allowlist ---

  function positionManagerKind(address positionManager_) external view override returns (LockKind kind, bool allowed) {
    return (_pmKind[positionManager_], _pmAllowed[positionManager_]);
  }

  function setPositionManager(address positionManager_, LockKind kind_, bool allowed_) external override onlyOwner {
    if (positionManager_ == address(0)) revert ZeroAddress();
    if (kind_ != LockKind.UNIV3 && kind_ != LockKind.UNIV4) revert InvalidPositionManagerKind();
    _pmKind[positionManager_] = kind_;
    _pmAllowed[positionManager_] = allowed_;
    emit PositionManagerSet(positionManager_, kind_, allowed_);
  }

  // --- ERC20 lock creation ---

  function createTokenLock(
    address tokenAddress_,
    uint256 amount_,
    uint40 unlockTime_
  ) external payable override allowCreation nonReentrant {
    uint40 id = _tokenLockerCount++;
    uint256 amountToLock = _collectFee(id, tokenAddress_, amount_);

    TitanLockerV2 locker = new TitanLockerV2(
      address(this), id, _msgSender(), LockKind.ERC20, tokenAddress_, 0, unlockTime_, 0, 0, 0, 0
    );
    _tokenLockers[id] = locker;

    IERC20(tokenAddress_).safeTransferFrom(_msgSender(), address(locker), amountToLock);

    _indexNewLocker(id, tokenAddress_, locker);

    (, address token0, address token1) = locker.getUnderlyingTokens();
    _indexUnderlying(id, token0, token1);

    emit TokenLockerCreated(
      id,
      tokenAddress_,
      token0,
      token1,
      _msgSender(),
      IERC20(tokenAddress_).balanceOf(address(locker)),
      unlockTime_
    );
  }

  /// @dev Either takes the flat `_ethFee` (100% of `amount_` gets locked), or -
  /// when no ETH is sent - deducts `_tokenFeeBps` from `amount_` in the token
  /// itself. Exempt accounts pay nothing and must not send ETH.
  function _collectFee(uint40 id_, address tokenAddress_, uint256 amount_) private returns (uint256 amountToLock) {
    bool paidInEth = msg.value != 0;

    if (_feeExempt[_msgSender()]) {
      if (paidInEth) revert ExemptAccountsPayNoEth();
      return amount_;
    }

    if (paidInEth) {
      if (msg.value != _ethFee) revert IncorrectEthFee(_ethFee, msg.value);
      (bool success, ) = _feeReceiver.call{value: msg.value}("");
      if (!success) revert EthTransferFailed();
      emit FeeCollected(id_, true, msg.value);
      return amount_;
    }

    uint256 tokenFeeAmount = (amount_ * _tokenFeeBps) / BPS_DENOMINATOR;
    amountToLock = amount_ - tokenFeeAmount;

    if (tokenFeeAmount != 0) {
      IERC20(tokenAddress_).safeTransferFrom(_msgSender(), _feeReceiver, tokenFeeAmount);
      emit FeeCollected(id_, false, tokenFeeAmount);
    }
  }

  // --- vesting lock creation ---

  /// @dev Locks a fungible token and releases it linearly (with an optional
  /// cliff) to the lock owner between `start_` and `end_`. Same creation-fee
  /// options as `createTokenLock`; the vesting grant is the post-fee amount and
  /// is irrevocable.
  function createVestingLock(
    address tokenAddress_,
    uint256 amount_,
    uint40 start_,
    uint40 cliff_,
    uint40 end_
  ) external payable override allowCreation nonReentrant {
    if (start_ >= end_ || cliff_ < start_ || cliff_ > end_ || end_ <= uint40(block.timestamp)) {
      revert InvalidVestingSchedule();
    }

    uint40 id = _tokenLockerCount++;
    uint256 amountToLock = _collectFee(id, tokenAddress_, amount_);

    // Grant is the nominal post-fee amount; `release()` clamps payouts to the
    // lock's live balance, so fee-on-transfer shortfalls can never over-release.
    TitanLockerV2 locker = new TitanLockerV2(
      address(this), id, _msgSender(), LockKind.ERC20_VESTING, tokenAddress_, 0, end_, start_, cliff_, end_, amountToLock
    );
    _tokenLockers[id] = locker;

    IERC20(tokenAddress_).safeTransferFrom(_msgSender(), address(locker), amountToLock);

    _indexNewLocker(id, tokenAddress_, locker);

    (, address token0, address token1) = locker.getUnderlyingTokens();
    _indexUnderlying(id, token0, token1);

    emit VestingLockerCreated(id, tokenAddress_, token0, token1, _msgSender(), amountToLock, start_, cliff_, end_);
  }

  // --- V3/V4 position lock creation ---

  function createPositionLock(
    address positionManager_,
    uint256 tokenId_,
    uint40 unlockTime_
  ) external payable override allowCreation nonReentrant {
    if (!_pmAllowed[positionManager_]) revert PositionManagerNotAllowed(positionManager_);
    LockKind kind = _pmKind[positionManager_];

    uint40 id = _tokenLockerCount++;
    _collectEthFee(id);

    TitanLockerV2 locker = new TitanLockerV2(
      address(this), id, _msgSender(), kind, positionManager_, tokenId_, unlockTime_, 0, 0, 0, 0
    );
    _tokenLockers[id] = locker;

    // Pull the position NFT from the depositor into the lock. Requires the
    // depositor to have approved this manager as an operator for it.
    IERC721(positionManager_).safeTransferFrom(_msgSender(), address(locker), tokenId_);

    _indexNewLocker(id, positionManager_, locker);

    (, address token0, address token1) = locker.getUnderlyingTokens();
    _indexUnderlying(id, token0, token1);

    emit PositionLockerCreated(id, kind, positionManager_, tokenId_, token0, token1, _msgSender(), unlockTime_);
  }

  /// @dev Flat-ETH-fee path used by position locks (no in-kind option exists
  /// for an NFT). Exempt accounts pay nothing and must not send ETH.
  function _collectEthFee(uint40 id_) private {
    if (_feeExempt[_msgSender()]) {
      if (msg.value != 0) revert ExemptAccountsPayNoEth();
      return;
    }

    if (msg.value != _ethFee) revert IncorrectEthFee(_ethFee, msg.value);

    if (msg.value != 0) {
      (bool success, ) = _feeReceiver.call{value: msg.value}("");
      if (!success) revert EthTransferFailed();
      emit FeeCollected(id_, true, msg.value);
    }
  }

  // --- indexing ---

  /// @dev Records a new locker in the creator / asset / locker-address buckets.
  function _indexNewLocker(uint40 id_, address asset_, TitanLockerV2 locker_) private {
    _tokenLockersForAddress[_msgSender()].push(id_);
    _tokenLockersForAddress[asset_].push(id_);
    _tokenLockersForAddress[address(locker_)].push(id_);
  }

  /// @dev Records the lock under each underlying paired token, when present.
  function _indexUnderlying(uint40 id_, address token0_, address token1_) private {
    if (token0_ != address(0)) _tokenLockersForAddress[token0_].push(id_);
    if (token1_ != address(0)) _tokenLockersForAddress[token1_].push(id_);
  }

  // --- reads ---

  function getTokenLockAddress(uint40 id_) external view override returns (address) {
    return address(_tokenLockers[id_]);
  }

  function getTokenLockData(uint40 id_) external view override returns (
    LockKind kind,
    uint40 id,
    address contractAddress,
    address lockOwner,
    address asset,
    uint256 tokenId,
    address createdBy,
    uint40 createdAt,
    uint40 unlockTime,
    uint256 balance
  ) {
    return _tokenLockers[id_].getLockData();
  }

  function getTokenLockersForAddress(address address_) external view override returns (uint40[] memory) {
    return _tokenLockersForAddress[address_];
  }

  /// @dev Called by a `TitanLockerV2` whenever its ownership changes, so the
  /// search index above stays accurate.
  function notifyLockerOwnerChange(
    uint40 id_,
    address newOwner_,
    address previousOwner_,
    address createdBy_
  ) external override {
    if (_msgSender() != address(_tokenLockers[id_])) revert CallerIsNotLocker(id_, _msgSender());

    if (previousOwner_ != createdBy_) {
      uint40[] storage previousOwnerLocks = _tokenLockersForAddress[previousOwner_];
      for (uint256 i = 0; i < previousOwnerLocks.length; i++) {
        if (previousOwnerLocks[i] != id_) continue;
        previousOwnerLocks[i] = previousOwnerLocks[previousOwnerLocks.length - 1];
        previousOwnerLocks.pop();
        break;
      }
    }

    uint40[] storage newOwnerLocks = _tokenLockersForAddress[newOwner_];
    for (uint256 i = 0; i < newOwnerLocks.length; i++) {
      if (newOwnerLocks[i] == id_) return;
    }
    newOwnerLocks.push(id_);
  }

  // --- fee configuration ---

  function ethFee() external view override returns (uint256) {
    return _ethFee;
  }

  function tokenFeeBps() external view override returns (uint16) {
    return _tokenFeeBps;
  }

  function feeReceiver() external view override returns (address) {
    return _feeReceiver;
  }

  function isExemptFromFees(address account_) external view override returns (bool) {
    return _feeExempt[account_];
  }

  function setEthFee(uint256 value_) external override onlyOwner {
    _ethFee = value_;
    emit FeeConfigUpdated(_ethFee, _tokenFeeBps, _feeReceiver);
  }

  function setTokenFeeBps(uint16 value_) external override onlyOwner {
    if (value_ > BPS_DENOMINATOR) revert TokenFeeTooHigh();
    _tokenFeeBps = value_;
    emit FeeConfigUpdated(_ethFee, _tokenFeeBps, _feeReceiver);
  }

  function setFeeReceiver(address payable value_) external override onlyOwner {
    if (value_ == address(0)) revert ZeroAddress();
    _feeReceiver = value_;
    emit FeeConfigUpdated(_ethFee, _tokenFeeBps, _feeReceiver);
  }

  function setFeeExempt(address account_, bool exempt_) external override onlyOwner {
    _feeExempt[account_] = exempt_;
  }
}
