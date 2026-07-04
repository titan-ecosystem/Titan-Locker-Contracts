// SPDX-License-Identifier: GPL-3.0-or-later

/**
  ___________________    _   __   __    ____  ________ __ __________
 /_  __/  _/_  __/   |  / | / /  / /   / __ \/ ____/ //_// ____/ __ \
  / /  / /  / / / /| | /  |/ /  / /   / / / / /   / ,<  / __/ / /_/ /
 / / _/ /  / / / ___ |/ /|  /  / /___/ /_/ / /___/ /| |/ /___/ _, _/
/_/ /___/ /_/ /_/  |_/_/ |_/  /_____/\____/\____/_/ |_/_____/_/ |_|

  Locker manager / factory
*/
pragma solidity 0.8.30;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITitanLockerManagerV1 } from "./ITitanLockerManagerV1.sol";
import { Ownable } from "./Ownable.sol";
import { TitanLockerV1 } from "./TitanLockerV1.sol";

/// @notice Deploys and indexes `TitanLockerV1` instances. Charges a creation
/// fee that the caller may pay either in ETH (locking 100% of the deposit)
/// or by letting a percentage of the deposited token itself be taken as the fee.
contract TitanLockerManagerV1 is ITitanLockerManagerV1, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  error CreationDisabled();
  error IncorrectEthFee(uint256 expected, uint256 received);
  error ExemptAccountsPayNoEth();
  error TokenFeeTooHigh();
  error CallerIsNotLocker(uint40 id, address caller);
  error EthTransferFailed();

  uint16 private constant BPS_DENOMINATOR = 10000;

  bool private _creationEnabled = true;
  uint40 private _tokenLockerCount;

  mapping(uint40 => TitanLockerV1) private _tokenLockers;
  /// @dev Lets the frontend search lockers by creator, locked token, locker
  /// address, or (for LP tokens) either underlying paired token.
  mapping(address => uint40[]) private _tokenLockersForAddress;

  uint256 private _ethFee;
  uint16 private _tokenFeeBps;
  address payable private _feeReceiver;
  mapping(address => bool) private _feeExempt;

  constructor(address payable feeReceiver_) Ownable(_msgSender()) {
    if (feeReceiver_ == address(0)) revert ZeroAddress();
    _feeReceiver = feeReceiver_;
    // starting values match the fee already on file for lock creation in the
    // upstream project's fee schedule; both are adjustable via setters below.
    _ethFee = 0.2 ether;
    _tokenFeeBps = 500; // 5.00%
  }

  modifier allowCreation() {
    if (!_creationEnabled) revert CreationDisabled();
    _;
  }

  // --- core locker lifecycle ---

  function tokenLockerCount() external view override returns (uint40) {
    return _tokenLockerCount;
  }

  function creationEnabled() external view override returns (bool) {
    return _creationEnabled;
  }

  /// @dev Turns off new locks so users can be migrated to a future version.
  /// Existing locks can still be extended/deposited/withdrawn as normal.
  function setCreationEnabled(bool value_) external override onlyOwner {
    _creationEnabled = value_;
  }

  function createTokenLocker(
    address tokenAddress_,
    uint256 amount_,
    uint40 unlockTime_
  ) external payable override allowCreation nonReentrant {
    uint40 id = _tokenLockerCount++;
    uint256 amountToLock = _collectFee(id, tokenAddress_, amount_);

    TitanLockerV1 locker = new TitanLockerV1(address(this), id, _msgSender(), tokenAddress_, unlockTime_);
    _tokenLockers[id] = locker;

    IERC20(tokenAddress_).safeTransferFrom(_msgSender(), address(locker), amountToLock);

    _indexNewLocker(id, tokenAddress_, unlockTime_, locker);
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

  /// @dev Records the new locker in every address-keyed search bucket the
  /// frontend looks lockers up by, then announces creation.
  function _indexNewLocker(uint40 id_, address tokenAddress_, uint40 unlockTime_, TitanLockerV1 locker_) private {
    address lockerAddress = address(locker_);

    _tokenLockersForAddress[_msgSender()].push(id_);
    _tokenLockersForAddress[tokenAddress_].push(id_);
    _tokenLockersForAddress[lockerAddress].push(id_);

    (bool hasLpData, , address token0Address, address token1Address, , , , ) = locker_.getLpData();
    if (hasLpData) {
      _tokenLockersForAddress[token0Address].push(id_);
      _tokenLockersForAddress[token1Address].push(id_);
    }

    emit TokenLockerCreated(
      id_,
      tokenAddress_,
      token0Address,
      token1Address,
      _msgSender(),
      IERC20(tokenAddress_).balanceOf(lockerAddress),
      unlockTime_
    );
  }

  function getTokenLockAddress(uint40 id_) external view override returns (address) {
    return address(_tokenLockers[id_]);
  }

  function getTokenLockData(uint40 id_) external view override returns (
    bool isLpToken,
    uint40 id,
    address contractAddress,
    address lockOwner,
    address token,
    address createdBy,
    uint40 createdAt,
    uint40 unlockTime,
    uint256 balance,
    uint256 totalSupply
  ) {
    return _tokenLockers[id_].getLockData();
  }

  function getLpData(uint40 id_) external view override returns (
    bool hasLpData,
    uint40 id,
    address token0,
    address token1,
    uint256 balance0,
    uint256 balance1,
    uint256 price0,
    uint256 price1
  ) {
    return _tokenLockers[id_].getLpData();
  }

  function getTokenLockersForAddress(address address_) external view override returns (uint40[] memory) {
    return _tokenLockersForAddress[address_];
  }

  /// @dev Called by a `TitanLockerV1` whenever its ownership changes, so the
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
