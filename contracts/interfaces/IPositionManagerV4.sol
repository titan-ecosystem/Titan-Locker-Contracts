// SPDX-License-Identifier: GPL-3.0-or-later

/**
  ___________________    _   __   __    ____  ________ __ __________
 /_  __/  _/_  __/   |  / | / /  / /   / __ \/ ____/ //_// ____/ __ \
  / /  / /  / / / /| | /  |/ /  / /   / / / / /   / ,<  / __/ / /_/ /
 / / _/ /  / / / ___ |/ /|  /  / /___/ /_/ / /___/ /| |/ /___/ _, _/
/_/ /___/ /_/ /_/  |_/_/ |_/  /_____/\____/\____/_/ |_/_____/_/ |_|

  Uniswap V4 PositionManager interface (minimal subset)
*/
pragma solidity 0.8.30;

/// @notice A V4 pool is identified by this key. `currency0`/`currency1` are the
/// two tokens (address(0) means native ETH). We only read the currencies.
struct PoolKeyV4 {
  address currency0;
  address currency1;
  uint24 fee;
  int24 tickSpacing;
  address hooks;
}

/// @notice The subset of the Uniswap V4 periphery `PositionManager` (an ERC721)
/// that the locker relies on. Fee collection in V4 is expressed as a
/// `modifyLiquidities` batch: a DECREASE_LIQUIDITY of zero liquidity (which
/// realises the accrued fees) followed by a TAKE_PAIR that sends both
/// currencies to a recipient.
/// @dev The position NFT is a standard ERC721; transfer/ownership go through
/// `IERC721`, so they are not redeclared here.
interface IPositionManagerV4 {
  /// @notice Executes an encoded batch of position actions. `unlockData` is
  /// `abi.encode(bytes actions, bytes[] params)`. `deadline` bounds execution.
  function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

  /// @notice Returns the pool key (from which we read the two currencies) and a
  /// packed position-info word for `tokenId`.
  function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKeyV4 memory poolKey, uint256 info);
}

/// @notice The two V4 action opcodes the locker encodes for a fee collection.
/// Mirrors the values in v4-periphery's `Actions` library.
library ActionsV4 {
  uint8 internal constant DECREASE_LIQUIDITY = 0x01;
  uint8 internal constant TAKE_PAIR = 0x11;
}
