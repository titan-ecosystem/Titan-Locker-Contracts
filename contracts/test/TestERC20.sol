// SPDX-License-Identifier: GPL-3.0-or-later
// Titan Locker - test-only ERC20, not part of the locker product
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mints the full supply to the deployer on construction. Used only by
/// the test suite and local deploy scripts as something to lock.
contract TestERC20 is ERC20 {
  constructor(string memory name_, string memory symbol_, uint256 supply_) ERC20(name_, symbol_) {
    _mint(msg.sender, supply_ * (10 ** decimals()));
  }
}
