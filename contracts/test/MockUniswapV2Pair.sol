// SPDX-License-Identifier: GPL-3.0-or-later
// Titan Locker - test-only mock LP pair, not part of the locker product
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A real Uniswap V2 pair is itself an ERC20 (the LP token), so this
/// mock is one too, minted a supply on deploy - lets the test suite lock an
/// "LP token" through the real deposit/withdraw path, not just read its data.
/// Exposes the fields Util.getLpData/isLpToken actually read (token0/token1/
/// price0CumulativeLast/price1CumulativeLast).
contract MockUniswapV2Pair is ERC20 {
  address public token0;
  address public token1;
  uint256 public price0CumulativeLast;
  uint256 public price1CumulativeLast;

  constructor(
    address token0_,
    address token1_,
    uint256 price0_,
    uint256 price1_,
    uint256 lpSupply_
  ) ERC20("Mock LP", "MLP") {
    token0 = token0_;
    token1 = token1_;
    price0CumulativeLast = price0_;
    price1CumulativeLast = price1_;
    _mint(msg.sender, lpSupply_);
  }
}
