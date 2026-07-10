// SPDX-License-Identifier: GPL-3.0-or-later

/**
  Test-only adversary. NOT part of the locker product. Models a malicious lock
  OWNER that, when it receives an NFT (e.g. while rescuing a stray NFT), tries to
  re-enter the lock. Used to prove the reentrancy guards hold even when the owner
  itself is hostile.
*/
pragma solidity 0.8.30;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { TitanLockerV2 } from "../TitanLockerV2.sol";

contract ReentrantLockOwner is IERC721Receiver {
  TitanLockerV2 public lock;
  bool public armed;
  bool public reentryReverted;
  bool public reentryTried;

  function setLock(address lock_) external {
    lock = TitanLockerV2(payable(lock_));
  }

  function arm() external {
    armed = true;
  }

  // owner-proxied entry points (this contract is the lock owner)
  function callWithdrawNft(address collection_, uint256 tokenId_) external {
    lock.withdrawNft(collection_, tokenId_);
  }

  function callWithdraw() external {
    lock.withdraw();
  }

  function callTransferOwnership(address to_) external {
    lock.transferOwnership(to_);
  }

  function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
    if (armed) {
      armed = false; // one-shot, avoid infinite recursion
      reentryTried = true;
      // attempt to re-enter a guarded function mid-rescue - must revert
      try lock.withdraw() {
        reentryReverted = false;
      } catch {
        reentryReverted = true;
      }
    }
    return this.onERC721Received.selector;
  }

  receive() external payable {}
}
