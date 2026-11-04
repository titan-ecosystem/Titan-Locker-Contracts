// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";

/// @dev Small model of ERC404's relevant behavior: every whole fungible token
/// has a transferable NFT, and moving the NFT moves the fungible unit too.
contract LinkedERC20ERC721 {
    uint256 public constant UNIT = 1 ether;
    uint256 public constant ID = (1 << 255) + 1;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public nftOwner;

    constructor() {
        balanceOf[msg.sender] = UNIT;
        nftOwner = msg.sender;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 valueOrId) public returns (bool) {
        if (valueOrId == ID) {
            require(msg.sender == from && nftOwner == from, "unauthorized NFT transfer");
            _move(from, to, UNIT);
        } else {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - valueOrId;
            _move(from, to, valueOrId);
        }
        return true;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(id == ID, "wrong NFT");
        transferFrom(from, to, id);
        if (to.code.length != 0) {
            (bool ok, bytes memory data) = to.call(abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)", msg.sender, from, id, bytes("")
            ));
            require(ok && abi.decode(data, (bytes4)) == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));
        }
    }

    function _move(address from, address to, uint256 value) private {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        if (value == UNIT) nftOwner = to;
    }
}

contract HybridTokenBypass is Test {
    TitanLockerManagerV2 manager;
    LinkedERC20ERC721 hybrid;

    function setUp() public {
        vm.warp(100);
        manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0.025 ether);
        vm.deal(address(this), 1 ether);
        hybrid = new LinkedERC20ERC721();
        hybrid.approve(address(manager), type(uint256).max);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function testTokenLockRejectsLinkedNftRescueBeforeUnlock() public {
        manager.createTokenLock{value: 0.025 ether}(address(hybrid), 1 ether, 200, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(hybrid.balanceOf(address(locker)), 1 ether);
        assertEq(hybrid.nftOwner(), address(locker));
        assertLt(block.timestamp, 200);

        uint256 id = hybrid.ID();
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        locker.withdrawNft(address(hybrid), id);
        assertEq(hybrid.balanceOf(address(locker)), 1 ether);
        assertEq(hybrid.balanceOf(address(this)), 0);
        assertEq(hybrid.nftOwner(), address(locker));
        vm.warp(200);
        locker.withdraw();
        assertEq(hybrid.balanceOf(address(this)), 1 ether);
    }

    function testVestingLockRejectsLinkedNftRescueBeforeCliff() public {
        manager.createVestingLock{value: 0.025 ether}(address(hybrid), 1 ether, 110, 110, 200, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(hybrid.balanceOf(address(locker)), 1 ether);
        assertEq(hybrid.nftOwner(), address(locker));
        assertLt(block.timestamp, 110);

        uint256 id = hybrid.ID();
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        locker.withdrawNft(address(hybrid), id);
        assertEq(hybrid.balanceOf(address(locker)), 1 ether);
        vm.warp(200);
        assertEq(locker.release(), 1 ether);
        assertEq(hybrid.balanceOf(address(this)), 1 ether);
    }
}
