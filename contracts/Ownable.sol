// SPDX-License-Identifier: GPL-3.0-or-later
// Titan Locker - access control primitive
pragma solidity 0.8.30;

import { Context } from "@openzeppelin/contracts/utils/Context.sol";

/// @notice Single-owner access control with an overridable transfer hook,
/// so subclasses can react (e.g. update an external index) when ownership moves.
abstract contract Ownable is Context {
  error CallerNotOwner(address caller);
  error ZeroAddress();

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  address private _currentOwner;

  constructor(address initialOwner_) {
    _currentOwner = initialOwner_;
    emit OwnershipTransferred(address(0), initialOwner_);
  }

  modifier onlyOwner() {
    if (_msgSender() != _currentOwner) revert CallerNotOwner(_msgSender());
    _;
  }

  function _owner() internal view returns (address) {
    return _currentOwner;
  }

  function owner() external view returns (address) {
    return _currentOwner;
  }

  /// @dev Reverts on a zero-address target so ownership can never be bricked
  /// by accident; there is deliberately no "renounce ownership" escape hatch.
  function transferOwnership(address newOwner_) external onlyOwner {
    if (newOwner_ == address(0)) revert ZeroAddress();
    _transferOwnership(newOwner_);
  }

  function _transferOwnership(address newOwner_) internal virtual onlyOwner {
    address previousOwner = _currentOwner;
    _currentOwner = newOwner_;
    emit OwnershipTransferred(previousOwner, newOwner_);
  }
}
