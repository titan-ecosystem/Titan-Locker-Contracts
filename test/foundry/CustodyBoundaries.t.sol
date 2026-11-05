// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";
import {Ownable} from "../../contracts/Ownable.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {MockNonfungiblePositionManagerV3} from "../../contracts/test/MockNonfungiblePositionManagerV3.sol";
import {MockPositionManagerV4} from "../../contracts/test/MockPositionManagerV4.sol";

/// @dev One contract exposes ERC20 balances and an independently transferable
/// NFT. The two balances are deliberately not linked, unlike ERC404.
contract IndependentDualToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public nftOwner;

    constructor() {
        balanceOf[msg.sender] = 100;
        nftOwner = msg.sender;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(tokenId == 1 && nftOwner == from && msg.sender == from);
        nftOwner = to;
        if (to.code.length > 0) {
            (bool ok, bytes memory result) = to.call(abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)", msg.sender, from, tokenId, bytes("")
            ));
            require(ok && abi.decode(result, (bytes4)) == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));
        }
    }
}

contract CustodyBoundaries is Test {
    uint40 constant UNLOCK = 200;
    TitanLockerV2 tokenLock;
    TitanLockerV2 vestingLock;
    TitanLockerV2 v3Lock;
    TitanLockerV2 v4Lock;
    TestERC20 token;
    MockNonfungiblePositionManagerV3 v3;
    MockPositionManagerV4 v4;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setUp() public {
        vm.warp(100);
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0);
        manager.setTokenFeeBps(0);
        token = new TestERC20("Custody", "CST", 1000);
        token.approve(address(manager), type(uint256).max);

        manager.createTokenLock(address(token), 100 ether, UNLOCK, 0);
        tokenLock = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        manager.createVestingLock(address(token), 100 ether, 110, 120, UNLOCK, 0);
        vestingLock = TitanLockerV2(payable(manager.getTokenLockAddress(1)));

        v3 = new MockNonfungiblePositionManagerV3();
        uint256 v3Id = v3.mint(address(this), address(token), address(0xBEEF), 0, 0);
        v3.approve(address(manager), v3Id);
        manager.setPositionManager(address(v3), ITitanLockerManagerV2.LockKind.UNIV3, true);
        manager.createPositionLock(address(v3), v3Id, UNLOCK);
        v3Lock = TitanLockerV2(payable(manager.getTokenLockAddress(2)));

        v4 = new MockPositionManagerV4();
        uint256 v4Id = v4.mint(address(this), address(token), address(0xBEEF), 0, 0);
        v4.approve(address(manager), v4Id);
        manager.setPositionManager(address(v4), ITitanLockerManagerV2.LockKind.UNIV4, true);
        manager.createPositionLock(address(v4), v4Id, UNLOCK);
        v4Lock = TitanLockerV2(payable(manager.getTokenLockAddress(3)));
    }

    function testAllPrincipalExitPathsHoldUntilExactUnlock() public {
        vm.warp(UNLOCK - 1);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, UNLOCK));
        tokenLock.withdraw();
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, UNLOCK));
        tokenLock.withdrawTo(address(this));
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        tokenLock.withdrawToken(address(token));
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        tokenLock.withdrawNft(address(token), 0);

        vm.expectRevert(TitanLockerV2.WrongLockKind.selector);
        vestingLock.withdraw();
        vm.expectRevert(TitanLockerV2.WrongLockKind.selector);
        vestingLock.withdrawTo(address(this));
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        vestingLock.withdrawToken(address(token));
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        vestingLock.withdrawNft(address(token), 0);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, UNLOCK));
        vestingLock.withdrawVestingSurplus();

        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, UNLOCK));
        v3Lock.withdraw();
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, UNLOCK));
        v3Lock.withdrawTo(address(this));
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        v3Lock.withdrawNft(address(v3), 0);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, UNLOCK));
        v4Lock.withdraw();
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, UNLOCK));
        v4Lock.withdrawTo(address(this));
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        v4Lock.withdrawNft(address(v4), 0);
        assertEq(v3.ownerOf(0), address(v3Lock));
        assertEq(v4.ownerOf(0), address(v4Lock));
        assertEq(token.balanceOf(address(tokenLock)), 100 ether);
        assertEq(token.balanceOf(address(vestingLock)), 100 ether);

        vm.warp(UNLOCK);
        tokenLock.withdraw();
        assertEq(token.balanceOf(address(tokenLock)), 0);
        assertEq(vestingLock.release(), 100 ether);
        assertEq(token.balanceOf(address(vestingLock)), 0);
        v3Lock.withdraw();
        v4Lock.withdrawTo(address(this));
        assertEq(v3.ownerOf(0), address(this));
        assertEq(v4.ownerOf(0), address(this));
    }

    function testNonOwnerCannotTakeAssetsEvenAfterUnlock() public {
        vm.warp(UNLOCK);
        address attacker = address(0xBAD);
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        tokenLock.withdraw();
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        vestingLock.release();
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        v3Lock.withdraw();
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        v4Lock.withdraw();
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        v4Lock.withdrawTo(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        v4Lock.withdrawNft(address(v4), 0);
        vm.stopPrank();
        assertEq(v3.ownerOf(0), address(v3Lock));
        assertEq(v4.ownerOf(0), address(v4Lock));
    }

    function testSameCollectionStrayNftRecoverableOnlyAfterMaturity() public {
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setTokenFeeBps(0);
        IndependentDualToken hybrid = new IndependentDualToken();
        hybrid.approve(address(manager), 10);
        manager.createTokenLock(address(hybrid), 10, UNLOCK, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        hybrid.safeTransferFrom(address(this), address(locker), 1);

        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        locker.withdrawNft(address(hybrid), 1);
        assertEq(hybrid.nftOwner(), address(locker));
        assertEq(hybrid.balanceOf(address(locker)), 10);

        vm.warp(UNLOCK);
        locker.withdrawNft(address(hybrid), 1);
        assertEq(hybrid.nftOwner(), address(this));
        assertEq(hybrid.balanceOf(address(locker)), 10);
        locker.withdraw();
        assertEq(hybrid.balanceOf(address(locker)), 0);
    }
}
