// SPDX-License-Identifier: GPL-3.0-or-later

/**
  Test-only mock of a Uniswap V4 PositionManager. NOT part of the locker
  product - it exists purely so the test suites can exercise the V4
  create -> collectFees -> withdraw path without a live Uniswap V4 deployment.
  It decodes the same `modifyLiquidities(DECREASE_LIQUIDITY + TAKE_PAIR)` batch
  the locker builds and pays the owed fees to the TAKE_PAIR recipient.
*/
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PoolKeyV4 } from "../interfaces/IPositionManagerV4.sol";
import { MockERC721Base } from "./MockERC721Base.sol";

contract MockPositionManagerV4 is MockERC721Base {
  struct Position {
    address currency0; // address(0) == native ETH
    address currency1;
    uint128 owed0;
    uint128 owed1;
  }

  uint256 private _nextId;
  mapping(uint256 => Position) private _positions;

  receive() external payable {}

  function mint(
    address to,
    address currency0,
    address currency1,
    uint128 owed0,
    uint128 owed1
  ) external returns (uint256 tokenId) {
    tokenId = _nextId++;
    _positions[tokenId] = Position(currency0, currency1, owed0, owed1);
    _mint(to, tokenId);
  }

  function setOwed(uint256 tokenId, uint128 owed0, uint128 owed1) external {
    _positions[tokenId].owed0 = owed0;
    _positions[tokenId].owed1 = owed1;
  }

  function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKeyV4 memory poolKey, uint256 info) {
    Position storage p = _positions[tokenId];
    poolKey = PoolKeyV4({
      currency0: p.currency0,
      currency1: p.currency1,
      fee: 3000,
      tickSpacing: 60,
      hooks: address(0)
    });
    info = 0;
  }

  /// @dev Decodes the locker's batch and pays owed fees to the TAKE_PAIR
  /// recipient. Only understands the (DECREASE_LIQUIDITY, TAKE_PAIR) shape the
  /// locker emits - enough to test the path structurally.
  function modifyLiquidities(bytes calldata unlockData, uint256 /*deadline*/) external payable {
    (, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));

    (uint256 tokenId, , , , ) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
    (address c0, address c1, address recipient) = abi.decode(params[1], (address, address, address));

    Position storage p = _positions[tokenId];
    uint128 owed0 = p.owed0;
    uint128 owed1 = p.owed1;
    p.owed0 = 0;
    p.owed1 = 0;

    _pay(c0, recipient, owed0);
    _pay(c1, recipient, owed1);
  }

  function _pay(address currency, address recipient, uint128 amount) private {
    if (amount == 0) return;
    if (currency == address(0)) {
      (bool ok, ) = payable(recipient).call{value: amount}("");
      require(ok, "eth pay failed");
    } else {
      IERC20(currency).transfer(recipient, amount);
    }
  }
}
