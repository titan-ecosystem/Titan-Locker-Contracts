// SPDX-License-Identifier: GPL-3.0-or-later
// Titan Locker - individual token lock
pragma solidity 0.8.30;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITitanLockerManagerV1 } from "./ITitanLockerManagerV1.sol";
import { Ownable } from "./Ownable.sol";
import { Util } from "./Util.sol";

/// @notice Holds one deposit of a single ERC20 (or LP) token until `unlockTime`,
/// deployed and tracked by a `TitanLockerManagerV1`.
contract TitanLockerV1 is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  error UnlockTimeNotInFuture();
  error UnlockTimeCannotBeReduced();
  error LockStillActive(uint40 unlockTime);
  error CannotSweepLockedToken();
  error EthTransferFailed();

  event UnlockTimeExtended(uint40 newUnlockTime);
  event TokensDeposited(uint256 amountReceived);
  event TokensWithdrawn();

  ITitanLockerManagerV1 private immutable _manager;
  IERC20 private immutable _token;
  address private immutable _createdBy;
  uint40 private immutable _id;
  uint40 private immutable _createdAt;
  bool private immutable _isLpToken;

  uint40 private _unlockTime;

  constructor(
    address manager_,
    uint40 id_,
    address owner_,
    address tokenAddress_,
    uint40 unlockTime_
  ) Ownable(owner_) {
    if (owner_ == address(0)) revert ZeroAddress();
    if (unlockTime_ <= uint40(block.timestamp)) revert UnlockTimeNotInFuture();

    _manager = ITitanLockerManagerV1(manager_);
    _id = id_;
    _token = IERC20(tokenAddress_);
    _createdBy = owner_;
    _createdAt = uint40(block.timestamp);
    _unlockTime = unlockTime_;
    _isLpToken = Util.isLpToken(tokenAddress_);
  }

  function _heldBalance() private view returns (uint256) {
    return _token.balanceOf(address(this));
  }

  function getIsLpToken() external view returns (bool) {
    return _isLpToken;
  }

  function getLockData() external view returns (
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
    isLpToken = _isLpToken;
    id = _id;
    contractAddress = address(this);
    lockOwner = _owner();
    token = address(_token);
    createdBy = _createdBy;
    createdAt = _createdAt;
    unlockTime = _unlockTime;
    balance = _heldBalance();
    totalSupply = _token.totalSupply();
  }

  function getLpData() external view returns (
    bool hasLpData,
    uint40 id,
    address token0,
    address token1,
    uint256 balance0,
    uint256 balance1,
    uint256 price0,
    uint256 price1
  ) {
    id = _id;

    if (!_isLpToken) {
      hasLpData = false;
      return (hasLpData, id, token0, token1, balance0, balance1, price0, price1);
    }

    try Util.getLpData(address(_token)) returns (
      address token0_,
      address token1_,
      uint256 balance0_,
      uint256 balance1_,
      uint256 price0_,
      uint256 price1_
    ) {
      hasLpData = true;
      token0 = token0_;
      token1 = token1_;
      balance0 = balance0_;
      balance1 = balance1_;
      price0 = price0_;
      price1 = price1_;
    } catch {
      hasLpData = false;
    }
  }

  /// @dev Top up the locked balance and/or push `unlockTime` further out, in one call.
  function deposit(uint256 amount_, uint40 newUnlockTime_) external onlyOwner nonReentrant {
    if (newUnlockTime_ != 0) {
      if (newUnlockTime_ < _unlockTime || newUnlockTime_ < uint40(block.timestamp)) {
        revert UnlockTimeCannotBeReduced();
      }
      _unlockTime = newUnlockTime_;
      emit UnlockTimeExtended(_unlockTime);
    }

    if (amount_ != 0) {
      uint256 balanceBefore = _heldBalance();
      _token.safeTransferFrom(_msgSender(), address(this), amount_);
      emit TokensDeposited(_heldBalance() - balanceBefore);
    }
  }

  function withdraw() external onlyOwner nonReentrant {
    if (uint40(block.timestamp) < _unlockTime) revert LockStillActive(_unlockTime);

    _token.safeTransfer(_owner(), _heldBalance());

    emit TokensWithdrawn();
  }

  /// @dev Rescue any token other than the one under lock (e.g. an airdrop
  /// or dividend that landed on this contract by accident).
  function withdrawToken(address tokenAddress_) external onlyOwner nonReentrant {
    if (tokenAddress_ == address(_token)) revert CannotSweepLockedToken();

    IERC20 stray = IERC20(tokenAddress_);
    stray.safeTransfer(_owner(), stray.balanceOf(address(this)));
  }

  /// @dev Rescue any ETH that landed on this contract (e.g. from a dividend token).
  function withdrawEth() external onlyOwner nonReentrant {
    (bool success, ) = payable(_owner()).call{value: address(this).balance}("");
    if (!success) revert EthTransferFailed();
  }

  function _transferOwnership(address newOwner_) internal override onlyOwner {
    address previousOwner = _owner();
    super._transferOwnership(newOwner_);

    // keep the manager's search index in sync with the new owner
    _manager.notifyLockerOwnerChange(_id, newOwner_, previousOwner, _createdBy);
  }

  /// @dev Accepts stray ETH (e.g. dividends); use `withdrawEth` to recover it.
  receive() external payable {}
}
