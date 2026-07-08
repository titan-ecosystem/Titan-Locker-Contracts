// SPDX-License-Identifier: GPL-3.0-or-later

/**
  ___________________    _   __   __    ____  ________ __ __________
 /_  __/  _/_  __/   |  / | / /  / /   / __ \/ ____/ //_// ____/ __ \
  / /  / /  / / / /| | /  |/ /  / /   / / / / /   / ,<  / __/ / /_/ /
 / / _/ /  / / / ___ |/ /|  /  / /___/ /_/ / /___/ /| |/ /___/ _, _/
/_/ /___/ /_/ /_/  |_/_/ |_/  /_____/\____/\____/_/ |_/_____/_/ |_|

  Uniswap V3 NonfungiblePositionManager interface (minimal subset)
*/
pragma solidity 0.8.30;

/// @notice The subset of the Uniswap V3 `NonfungiblePositionManager` (an
/// ERC721) that the locker relies on: reading a position's data and collecting
/// the trading fees accrued to it. V3 forks that keep the same ABI (e.g.
/// PancakeSwap V3) are compatible and can be allowlisted the same way.
/// @dev The position NFT itself is an ERC721; transfer/ownership calls go
/// through the standard `IERC721` interface, so they are intentionally not
/// redeclared here.
interface INonfungiblePositionManagerV3 {
  struct CollectParams {
    uint256 tokenId;
    address recipient;
    uint128 amount0Max;
    uint128 amount1Max;
  }

  /// @notice Sweeps the fees owed to `params.tokenId` to `params.recipient`.
  /// Passing `type(uint128).max` for both maxes collects everything owed.
  /// Only the position's owner or an approved operator may call it - the
  /// locker contract holds the NFT, so it qualifies.
  function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

  /// @notice Full position record. The locker reads `token0`/`token1` (to index
  /// the lock by its underlying pair) and exposes the rest to the frontend.
  function positions(uint256 tokenId) external view returns (
    uint96 nonce,
    address operator,
    address token0,
    address token1,
    uint24 fee,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity,
    uint256 feeGrowthInside0LastX128,
    uint256 feeGrowthInside1LastX128,
    uint128 tokensOwed0,
    uint128 tokensOwed1
  );
}
