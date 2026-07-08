// SPDX-License-Identifier: GPL-3.0-or-later

/**
  ___________________    _   __   __    ____  ________ __ __________
 /_  __/  _/_  __/   |  / | / /  / /   / __ \/ ____/ //_// ____/ __ \
  / /  / /  / / / /| | /  |/ /  / /   / / / / /   / ,<  / __/ / /_/ /
 / / _/ /  / / / ___ |/ /|  /  / /___/ /_/ / /___/ /| |/ /___/ _, _/
/_/ /___/ /_/ /_/  |_/_/ |_/  /_____/\____/\____/_/ |_/_____/_/ |_|

  Individual lock - holds one ERC20 balance OR one V3/V4 LP position
*/
pragma solidity 0.8.30;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ITitanLockerManagerV2 } from "./ITitanLockerManagerV2.sol";
import { INonfungiblePositionManagerV3 } from "./interfaces/INonfungiblePositionManagerV3.sol";
import { IPositionManagerV4, PoolKeyV4, ActionsV4 } from "./interfaces/IPositionManagerV4.sol";
import { Ownable } from "./Ownable.sol";
import { Util } from "./Util.sol";

/// @notice Holds exactly one asset until `unlockTime`: either a single ERC20
/// (plain token or V2-style LP token) balance, or a single Uniswap V3/V4 LP
/// position NFT. For NFT locks the owner may `collectFees` at any time while
/// the position stays locked. Deployed and tracked by a `TitanLockerManagerV2`.
///
/// @dev Custody is isolated by construction: one deployed instance holds one
/// asset, `_kind`/`_asset`/`_tokenId` are immutable, and every value-moving
/// entry point is `onlyOwner`. There is no shared balance or ledger, so no
/// lock can ever touch another lock's funds or fees.
contract TitanLockerV2 is Ownable, ERC721Holder, ReentrancyGuard {
  using SafeERC20 for IERC20;

  error UnlockTimeNotInFuture();
  error UnlockTimeCannotBeReduced();
  error LockStillActive(uint40 unlockTime);
  error CannotSweepLockedToken();
  error EthTransferFailed();
  error WrongLockKind();

  event UnlockTimeExtended(uint40 newUnlockTime);
  event TokensDeposited(uint256 amountReceived);
  event TokensWithdrawn();
  event PositionWithdrawn(uint256 tokenId);
  event FeesCollected(uint256 amount0, uint256 amount1);

  ITitanLockerManagerV2.LockKind private immutable _kind;
  ITitanLockerManagerV2 private immutable _manager;
  /// @dev ERC20 token address for ERC20 locks; position-manager address for
  /// V3/V4 locks.
  address private immutable _asset;
  /// @dev The position NFT id for V3/V4 locks; unused (0) for ERC20 locks.
  uint256 private immutable _tokenId;
  address private immutable _createdBy;
  uint40 private immutable _id;
  uint40 private immutable _createdAt;
  /// @dev Only meaningful for ERC20 locks - true if the token is a V2 LP pair.
  bool private immutable _isLpToken;

  uint40 private _unlockTime;

  constructor(
    address manager_,
    uint40 id_,
    address owner_,
    ITitanLockerManagerV2.LockKind kind_,
    address asset_,
    uint256 tokenId_,
    uint40 unlockTime_
  ) Ownable(owner_) {
    if (owner_ == address(0)) revert ZeroAddress();
    if (unlockTime_ <= uint40(block.timestamp)) revert UnlockTimeNotInFuture();

    _manager = ITitanLockerManagerV2(manager_);
    _id = id_;
    _kind = kind_;
    _asset = asset_;
    _tokenId = tokenId_;
    _createdBy = owner_;
    _createdAt = uint40(block.timestamp);
    _unlockTime = unlockTime_;
    _isLpToken = kind_ == ITitanLockerManagerV2.LockKind.ERC20 && Util.isLpToken(asset_);
  }

  modifier onlyErc20() {
    if (_kind != ITitanLockerManagerV2.LockKind.ERC20) revert WrongLockKind();
    _;
  }

  modifier onlyPosition() {
    if (_kind == ITitanLockerManagerV2.LockKind.ERC20) revert WrongLockKind();
    _;
  }

  // --- reads ---

  function _heldBalance() private view returns (uint256) {
    if (_kind != ITitanLockerManagerV2.LockKind.ERC20) return 0;
    return IERC20(_asset).balanceOf(address(this));
  }

  function getKind() external view returns (ITitanLockerManagerV2.LockKind) {
    return _kind;
  }

  function getLockData() external view returns (
    ITitanLockerManagerV2.LockKind kind,
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
    kind = _kind;
    id = _id;
    contractAddress = address(this);
    lockOwner = _owner();
    asset = _asset;
    tokenId = _tokenId;
    createdBy = _createdBy;
    createdAt = _createdAt;
    unlockTime = _unlockTime;
    balance = _heldBalance();
  }

  /// @notice The two underlying tokens of the locked asset, best-effort.
  /// V2 LP: the pair's `token0`/`token1`. V3/V4: the position's two tokens.
  /// Plain ERC20 or on any read failure: both zero with `hasData == false`.
  function getUnderlyingTokens() public view returns (bool hasData, address token0, address token1) {
    if (_kind == ITitanLockerManagerV2.LockKind.ERC20) {
      if (!_isLpToken) return (false, address(0), address(0));
      try Util.getLpData(_asset) returns (address t0, address t1, uint256, uint256, uint256, uint256) {
        return (true, t0, t1);
      } catch {
        return (false, address(0), address(0));
      }
    }

    if (_kind == ITitanLockerManagerV2.LockKind.UNIV3) {
      try INonfungiblePositionManagerV3(_asset).positions(_tokenId) returns (
        uint96, address, address t0, address t1, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128
      ) {
        return (true, t0, t1);
      } catch {
        return (false, address(0), address(0));
      }
    }

    // UNIV4
    try IPositionManagerV4(_asset).getPoolAndPositionInfo(_tokenId) returns (PoolKeyV4 memory key, uint256) {
      return (true, key.currency0, key.currency1);
    } catch {
      return (false, address(0), address(0));
    }
  }

  // --- unlock-time management (all kinds) ---

  /// @dev Push `unlockTime` further out. Never allowed to reduce it.
  function extendLock(uint40 newUnlockTime_) public onlyOwner {
    if (newUnlockTime_ < _unlockTime || newUnlockTime_ < uint40(block.timestamp)) {
      revert UnlockTimeCannotBeReduced();
    }
    _unlockTime = newUnlockTime_;
    emit UnlockTimeExtended(_unlockTime);
  }

  // --- ERC20 lock lifecycle ---

  /// @dev Top up the locked balance and/or push `unlockTime` further out.
  function deposit(uint256 amount_, uint40 newUnlockTime_) external onlyOwner onlyErc20 nonReentrant {
    if (newUnlockTime_ != 0) extendLock(newUnlockTime_);

    if (amount_ != 0) {
      uint256 balanceBefore = _heldBalance();
      IERC20(_asset).safeTransferFrom(_msgSender(), address(this), amount_);
      emit TokensDeposited(_heldBalance() - balanceBefore);
    }
  }

  // --- V3/V4 position fee claiming ---

  /// @notice Collect the trading fees accrued to the locked position and send
  /// them to the lock owner. Callable any time while the lock is active - this
  /// is the whole point of locking an LP position. Touches only this lock's own
  /// immutable `_tokenId`, so it can never reach another lock's fees.
  function collectFees() external onlyOwner onlyPosition nonReentrant returns (uint256 amount0, uint256 amount1) {
    address recipient = _owner();

    if (_kind == ITitanLockerManagerV2.LockKind.UNIV3) {
      (amount0, amount1) = INonfungiblePositionManagerV3(_asset).collect(
        INonfungiblePositionManagerV3.CollectParams({
          tokenId: _tokenId,
          recipient: recipient,
          amount0Max: type(uint128).max,
          amount1Max: type(uint128).max
        })
      );
    } else {
      // UNIV4: decrease liquidity by zero (realises fees) then take both
      // currencies straight to the owner.
      (PoolKeyV4 memory key, ) = IPositionManagerV4(_asset).getPoolAndPositionInfo(_tokenId);

      bytes memory actions = abi.encodePacked(ActionsV4.DECREASE_LIQUIDITY, ActionsV4.TAKE_PAIR);
      bytes[] memory params = new bytes[](2);
      params[0] = abi.encode(_tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
      params[1] = abi.encode(key.currency0, key.currency1, recipient);

      IPositionManagerV4(_asset).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    emit FeesCollected(amount0, amount1);
  }

  // --- withdrawal (after unlock) ---

  /// @dev Return the locked asset to the owner once the lock has matured.
  function withdraw() external onlyOwner nonReentrant {
    if (uint40(block.timestamp) < _unlockTime) revert LockStillActive(_unlockTime);

    if (_kind == ITitanLockerManagerV2.LockKind.ERC20) {
      IERC20(_asset).safeTransfer(_owner(), _heldBalance());
      emit TokensWithdrawn();
    } else {
      IERC721(_asset).safeTransferFrom(address(this), _owner(), _tokenId);
      emit PositionWithdrawn(_tokenId);
    }
  }

  // --- rescue (stray assets that are not the locked one) ---

  /// @dev Rescue any ERC20 other than an ERC20-lock's locked token (e.g. an
  /// airdrop or dividend). For NFT locks nothing is excluded - the locked asset
  /// is an NFT, not an ERC20, so this can never move it.
  function withdrawToken(address tokenAddress_) external onlyOwner nonReentrant {
    if (_kind == ITitanLockerManagerV2.LockKind.ERC20 && tokenAddress_ == _asset) revert CannotSweepLockedToken();

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
