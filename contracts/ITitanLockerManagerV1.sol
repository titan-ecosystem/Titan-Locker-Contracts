// SPDX-License-Identifier: GPL-3.0-or-later
// Titan Locker - locker manager interface
pragma solidity 0.8.30;

interface ITitanLockerManagerV1 {
  event TokenLockerCreated(
    uint40 id,
    address indexed token,
    address indexed token0,
    address indexed token1,
    address createdBy,
    uint256 balance,
    uint40 unlockTime
  );

  event FeeConfigUpdated(uint256 ethFee, uint16 tokenFeeBps, address indexed feeReceiver);
  event FeeCollected(uint40 indexed id, bool paidInEth, uint256 amount);

  function tokenLockerCount() external view returns (uint40);

  function creationEnabled() external view returns (bool);

  function setCreationEnabled(bool value_) external;

  /// @dev Two ways to pay the creation fee: send `ethFee()` wei with the call
  /// to lock 100% of `amount_`, or send 0 wei and have `tokenFeeBps()` deducted
  /// from `amount_` in the locked token itself.
  function createTokenLocker(
    address tokenAddress_,
    uint256 amount_,
    uint40 unlockTime_
  ) external payable;

  function getTokenLockAddress(uint40 id_) external view returns (address);

  function getTokenLockData(uint40 id_) external view returns (
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
  );

  function getLpData(uint40 id_) external view returns (
    bool hasLpData,
    uint40 id,
    address token0,
    address token1,
    uint256 balance0,
    uint256 balance1,
    uint256 price0,
    uint256 price1
  );

  function getTokenLockersForAddress(address address_) external view returns (uint40[] memory);

  function notifyLockerOwnerChange(
    uint40 id_,
    address newOwner_,
    address previousOwner_,
    address createdBy_
  ) external;

  function ethFee() external view returns (uint256);

  function tokenFeeBps() external view returns (uint16);

  function feeReceiver() external view returns (address);

  function isExemptFromFees(address account_) external view returns (bool);

  function setEthFee(uint256 value_) external;

  function setTokenFeeBps(uint16 value_) external;

  function setFeeReceiver(address payable value_) external;

  function setFeeExempt(address account_, bool exempt_) external;
}
