// SPDX-License-Identifier: GPL-3.0-or-later

/**
  Test-only minimal ERC721. NOT part of the locker product. Exists so the V3/V4
  position-manager mocks can be ERC721s without importing OpenZeppelin's full
  ERC721, whose `Strings`/`Bytes` dependency uses the Cancun-only `mcopy`
  opcode and therefore will not compile for this project's `london` target.
  Implements only what the locker touches: ownerOf, balanceOf, approvals, and
  safeTransferFrom with the receiver-callback check.
*/
pragma solidity 0.8.30;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

abstract contract MockERC721Base {
  mapping(uint256 => address) private _owners;
  mapping(address => uint256) private _balances;
  mapping(uint256 => address) private _tokenApprovals;
  mapping(address => mapping(address => bool)) private _operatorApprovals;

  event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
  event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
  event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

  error NotOwnerNorApproved();
  error NonexistentToken();
  error WrongFrom();
  error TransferToNonReceiver();
  error TransferToZero();

  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    // IERC165 (0x01ffc9a7) and IERC721 (0x80ac58cd)
    return interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd;
  }

  function balanceOf(address owner) external view returns (uint256) {
    return _balances[owner];
  }

  function ownerOf(uint256 tokenId) public view returns (address owner) {
    owner = _owners[tokenId];
    if (owner == address(0)) revert NonexistentToken();
  }

  function approve(address to, uint256 tokenId) external {
    address owner = ownerOf(tokenId);
    if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) revert NotOwnerNorApproved();
    _tokenApprovals[tokenId] = to;
    emit Approval(owner, to, tokenId);
  }

  function getApproved(uint256 tokenId) public view returns (address) {
    ownerOf(tokenId); // reverts if nonexistent
    return _tokenApprovals[tokenId];
  }

  function setApprovalForAll(address operator, bool approved) external {
    _operatorApprovals[msg.sender][operator] = approved;
    emit ApprovalForAll(msg.sender, operator, approved);
  }

  function isApprovedForAll(address owner, address operator) public view returns (bool) {
    return _operatorApprovals[owner][operator];
  }

  function _isApprovedOrOwner(address spender, uint256 tokenId) private view returns (bool) {
    address owner = ownerOf(tokenId);
    return spender == owner || _tokenApprovals[tokenId] == spender || _operatorApprovals[owner][spender];
  }

  function transferFrom(address from, address to, uint256 tokenId) public {
    if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerNorApproved();
    if (ownerOf(tokenId) != from) revert WrongFrom();
    if (to == address(0)) revert TransferToZero();

    delete _tokenApprovals[tokenId];
    _balances[from] -= 1;
    _balances[to] += 1;
    _owners[tokenId] = to;
    emit Transfer(from, to, tokenId);
  }

  function safeTransferFrom(address from, address to, uint256 tokenId) external {
    safeTransferFrom(from, to, tokenId, "");
  }

  function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
    transferFrom(from, to, tokenId);
    if (to.code.length > 0) {
      try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
        if (retval != IERC721Receiver.onERC721Received.selector) revert TransferToNonReceiver();
      } catch {
        revert TransferToNonReceiver();
      }
    }
  }

  function _mint(address to, uint256 tokenId) internal {
    if (to == address(0)) revert TransferToZero();
    if (_owners[tokenId] != address(0)) revert WrongFrom();
    _balances[to] += 1;
    _owners[tokenId] = to;
    emit Transfer(address(0), to, tokenId);
  }
}
