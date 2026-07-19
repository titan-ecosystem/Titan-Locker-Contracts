// SPDX-License-Identifier: GPL-3.0-or-later

/**
  ___________________    _   __   __    ____  ________ __ __________
 /_  __/  _/_  __/   |  / | / /  / /   / __ \/ ____/ //_// ____/ __ \
  / /  / /  / / / /| | /  |/ /  / /   / / / / /   / ,<  / __/ / /_/ /
 / / _/ /  / / / ___ |/ /|  /  / /___/ /_/ / /___/ /| |/ /___/ _, _/
/_/ /___/ /_/ /_/  |_/_/ |_/  /_____/\____/\____/_/ |_/_____/_/ |_|

  Locker manager interface (V2 - tokens + V2/V3/V4 LP)
*/
pragma solidity 0.8.30;

interface ITitanLockerManagerV2 {
  /// @notice What a lock holds and how it releases. ERC20 covers plain tokens
  /// and V2-style LP tokens (which are themselves ERC20), released 100% at
  /// `unlockTime`. UNIV3/UNIV4 are ERC721 LP positions. ERC20_VESTING is a
  /// fungible grant released linearly (with an optional cliff) between `start`
  /// and `end`. Appended in order, so existing values keep their numbers.
  enum LockKind { ERC20, UNIV3, UNIV4, ERC20_VESTING }

  event TokenLockerCreated(
    uint40 id,
    address indexed token,
    address indexed token0,
    address indexed token1,
    address createdBy,
    uint256 balance,
    uint40 unlockTime
  );

  event PositionLockerCreated(
    uint40 id,
    LockKind kind,
    address indexed positionManager,
    uint256 tokenId,
    address indexed token0,
    address indexed token1,
    address createdBy,
    uint40 unlockTime
  );

  event VestingLockerCreated(
    uint40 id,
    address indexed token,
    address indexed token0,
    address indexed token1,
    address createdBy,
    uint256 amount,
    uint40 start,
    uint40 cliff,
    uint40 end
  );

  event FeeConfigUpdated(uint256 ethFee, uint16 tokenFeeBps, address indexed feeReceiver);
  event FeeCollected(uint40 indexed id, bool paidInEth, uint256 amount);
  event PositionManagerSet(address indexed positionManager, LockKind kind, bool allowed);

  function tokenLockerCount() external view returns (uint40);

  function creationEnabled() external view returns (bool);

  function setCreationEnabled(bool value_) external;

  // --- lock creation ---

  /// @dev ERC20 (and V2-LP) path. Two ways to pay the creation fee: send
  /// `ethFee()` wei to lock 100% of `amount_`, or send 0 wei and have
  /// `tokenFeeBps()` deducted from `amount_` in the locked token itself - in
  /// which case the call reverts if the live `tokenFeeBps()` exceeds
  /// `maxTokenFeeBps_` (ignored on the ETH-fee path), protecting the caller
  /// against a fee change landing between submission and mining. Pass
  /// `type(uint16).max` to accept whatever the live rate is.
  function createTokenLock(
    address tokenAddress_,
    uint256 amount_,
    uint40 unlockTime_,
    uint16 maxTokenFeeBps_
  ) external payable;

  /// @dev Vesting path. Locks `amount_` of a fungible token and releases it
  /// linearly to the lock owner between `start_` and `end_`, with nothing
  /// claimable before `cliff_`. Requires `start_ < end_` and
  /// `start_ <= cliff_ <= end_`. Same creation-fee options (and the same
  /// `maxTokenFeeBps_` protection) as `createTokenLock`. The grant is
  /// irrevocable - there is no creator clawback.
  function createVestingLock(
    address tokenAddress_,
    uint256 amount_,
    uint40 start_,
    uint40 cliff_,
    uint40 end_,
    uint16 maxTokenFeeBps_
  ) external payable;

  /// @dev Uniswap V3/V4 path. `positionManager_` must be allowlisted; its
  /// registered kind decides how fees are later collected. Only the flat
  /// `ethFee()` applies (a percentage of an NFT is not possible). The caller
  /// must have approved this manager as an operator for the position NFT.
  function createPositionLock(
    address positionManager_,
    uint256 tokenId_,
    uint40 unlockTime_
  ) external payable;

  // --- position-manager allowlist ---

  /// @notice Kind registered for a position manager and whether it is allowed.
  /// `allowed_ == false` means positions cannot be locked against it.
  function positionManagerKind(address positionManager_) external view returns (LockKind kind, bool allowed);

  /// @dev Allowlist (or update/remove) a position manager. `kind_` must be
  /// UNIV3 or UNIV4. Set `allowed_` false to disable it for new locks.
  function setPositionManager(address positionManager_, LockKind kind_, bool allowed_) external;

  // --- reads ---

  function getTokenLockAddress(uint40 id_) external view returns (address);

  function getTokenLockData(uint40 id_) external view returns (
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
  );

  function getTokenLockersForAddress(address address_) external view returns (uint40[] memory);

  function notifyLockerOwnerChange(
    uint40 id_,
    address newOwner_,
    address previousOwner_,
    address createdBy_
  ) external;

  // --- fee configuration ---

  function ethFee() external view returns (uint256);

  function tokenFeeBps() external view returns (uint16);

  function feeReceiver() external view returns (address);

  function isExemptFromFees(address account_) external view returns (bool);

  function setEthFee(uint256 value_) external;

  function setTokenFeeBps(uint16 value_) external;

  function setFeeReceiver(address payable value_) external;

  function setFeeExempt(address account_, bool exempt_) external;
}
