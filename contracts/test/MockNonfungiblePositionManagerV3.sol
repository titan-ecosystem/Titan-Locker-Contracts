// SPDX-License-Identifier: GPL-3.0-or-later

/**
  Test-only mock of a Uniswap V3 NonfungiblePositionManager. NOT part of the
  locker product - it exists purely so the test suites can exercise the V3
  create -> collectFees -> withdraw path without a live Uniswap deployment.
*/
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC721Base } from "./MockERC721Base.sol";

/// @dev Mints position NFTs and pays out configurable "owed fees" from its own
/// balance on `collect`. Fund it with the two pool tokens before collecting.
contract MockNonfungiblePositionManagerV3 is MockERC721Base {
  struct Position {
    address token0;
    address token1;
    uint128 owed0;
    uint128 owed1;
  }

  struct CollectParams {
    uint256 tokenId;
    address recipient;
    uint128 amount0Max;
    uint128 amount1Max;
  }

  uint256 private _nextId;
  mapping(uint256 => Position) private _positions;

  /// @notice Mint a position NFT to `to` with the given underlying tokens and
  /// initial owed-fee amounts. Returns the new tokenId.
  function mint(
    address to,
    address token0,
    address token1,
    uint128 owed0,
    uint128 owed1
  ) external returns (uint256 tokenId) {
    tokenId = _nextId++;
    _positions[tokenId] = Position(token0, token1, owed0, owed1);
    _mint(to, tokenId);
  }

  /// @notice Set the currently-owed fees for a position (simulates fee accrual).
  function setOwed(uint256 tokenId, uint128 owed0, uint128 owed1) external {
    _positions[tokenId].owed0 = owed0;
    _positions[tokenId].owed1 = owed1;
  }

  function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1) {
    Position storage p = _positions[params.tokenId];

    amount0 = params.amount0Max < p.owed0 ? params.amount0Max : p.owed0;
    amount1 = params.amount1Max < p.owed1 ? params.amount1Max : p.owed1;

    p.owed0 -= uint128(amount0);
    p.owed1 -= uint128(amount1);

    if (amount0 != 0) IERC20(p.token0).transfer(params.recipient, amount0);
    if (amount1 != 0) IERC20(p.token1).transfer(params.recipient, amount1);
  }

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
  ) {
    Position storage p = _positions[tokenId];
    return (0, address(0), p.token0, p.token1, 3000, -887220, 887220, 1e18, 0, 0, p.owed0, p.owed1);
  }
}
