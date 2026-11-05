// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @notice PancakeSwap Infinity and SushiSwap V4 CL use this six-field pool key.
/// It differs from the five-field Uniswap V4 pool key even though both
/// position managers expose getPoolAndPositionInfo(uint256).
struct PoolKeyInfinity {
  address currency0;
  address currency1;
  address hooks;
  address poolManager;
  uint24 fee;
  bytes32 parameters;
}

interface IInfinityCLPositionManager {
  function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKeyInfinity memory poolKey, uint256 info);
  function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}
