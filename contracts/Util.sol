// SPDX-License-Identifier: GPL-3.0-or-later

/**
  ___________________    _   __   __    ____  ________ __ __________
 /_  __/  _/_  __/   |  / | / /  / /   / __ \/ ____/ //_// ____/ __ \
  / /  / /  / / / /| | /  |/ /  / /   / / / / /   / ,<  / __/ / /_/ /
 / / _/ /  / / / ___ |/ /|  /  / /___/ /_/ / /___/ /| |/ /___/ _, _/
/_/ /___/ /_/ /_/  |_/_/ |_/  /_____/\____/\____/_/ |_/_____/_/ |_|

  Shared token/LP inspection helpers
*/
pragma solidity 0.8.30;

import { IERC20Metadata as IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IUniswapV2Pair } from "./library/Dex.sol";

library Util {
  /// @dev Pulls the standard ERC20 metadata plus the caller's balance in one call.
  function getTokenData(address tokenAddress_) external view returns (
    string memory name,
    string memory symbol,
    uint8 decimals,
    uint256 totalSupply,
    uint256 balance
  ) {
    IERC20 token = IERC20(tokenAddress_);

    name = token.name();
    symbol = token.symbol();
    decimals = token.decimals();
    totalSupply = token.totalSupply();
    balance = token.balanceOf(msg.sender);
  }

  /// @dev Best-effort detection of a Uniswap-V2-style LP pair: a real pair
  /// exposes `token0()`; anything else (a plain ERC20, an EOA, etc.) reverts,
  /// which we treat as "not an LP token" rather than letting the call fail.
  function isLpToken(address tokenAddress_) external view returns (bool) {
    try IUniswapV2Pair(tokenAddress_).token0() returns (address token0Address) {
      return token0Address != address(0);
    } catch {
      return false;
    }
  }

  /// @dev Reverts if `pairAddress_` isn't actually an LP pair - callers should
  /// gate this behind `isLpToken` first unless they want that revert.
  function getLpData(address pairAddress_) external view returns (
    address token0,
    address token1,
    uint256 balance0,
    uint256 balance1,
    uint256 price0,
    uint256 price1
  ) {
    IUniswapV2Pair pair = IUniswapV2Pair(pairAddress_);

    token0 = pair.token0();
    token1 = pair.token1();
    balance0 = IERC20(token0).balanceOf(pairAddress_);
    balance1 = IERC20(token1).balanceOf(pairAddress_);
    price0 = pair.price0CumulativeLast();
    price1 = pair.price1CumulativeLast();
  }
}
