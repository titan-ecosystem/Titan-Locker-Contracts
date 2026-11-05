// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";

contract RejectNativeOwner {
    function claimTo(TitanLockerV2 locker, address recipient) external {
        locker.collectFeesTo(recipient);
    }

    function withdrawTo(TitanLockerV2 locker, address recipient) external {
        locker.withdrawTo(recipient);
    }
}

contract RobinhoodDexFork is Test {
    address private constant SUSHI_V3 = 0x51d0e5188afe12d502e29D982d20C190e7816107;
    address private constant PANCAKE_V3 = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address private constant SUSHI_V4_CL = 0xd3d35fBc4E44523CA3cD383C1948322Ddb42F644;
    address private constant PANCAKE_INFINITY_CL = 0xeaEA9253A0b75B936a965DbD35B2a3F01831DE74;

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _testV3Lifecycle(address pm, uint256 tokenId) private {
        assertEq(block.chainid, 4663, "wrong Robinhood network");
        assertGt(pm.code.length, 0);
        IERC721 nft = IERC721(pm);
        address originalOwner = nft.ownerOf(tokenId);
        vm.prank(originalOwner);
        nft.transferFrom(originalOwner, address(this), tokenId);

        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0.025 ether);
        manager.setTokenFeeBps(300);
        manager.setPositionManager(pm, ITitanLockerManagerV2.LockKind.UNIV3, true);
        nft.approve(address(manager), tokenId);
        vm.deal(address(this), 1 ether);
        uint256 feeBalanceBefore = address(0xFEE).balance;

        uint40 maturity = uint40(block.timestamp + 100);
        manager.createPositionLock{value: 0.025 ether}(pm, tokenId, maturity);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(nft.ownerOf(tokenId), address(locker));
        assertEq(address(0xFEE).balance - feeBalanceBefore, 0.025 ether);
        (bool hasData, address token0, address token1) = locker.getUnderlyingTokens();
        assertTrue(hasData);
        assertTrue(token0 != address(0) && token1 != address(0));
        vm.expectRevert();
        locker.withdrawTo(address(this));
        locker.collectFees();
        assertEq(nft.ownerOf(tokenId), address(locker));
        vm.warp(maturity);
        locker.withdrawTo(address(this));
        assertEq(nft.ownerOf(tokenId), address(this));
    }

    function testSushiV3RealPositionLifecycle() public { _testV3Lifecycle(SUSHI_V3, 1); }
    function testPancakeV3RealPositionLifecycle() public { _testV3Lifecycle(PANCAKE_V3, 1); }

    function _testInfinityClLifecycle(address pm, uint256 tokenId) private {
        assertEq(block.chainid, 4663, "wrong Robinhood network");
        IERC721 nft = IERC721(pm);
        address originalOwner = nft.ownerOf(tokenId);
        vm.prank(originalOwner);
        nft.transferFrom(originalOwner, address(this), tokenId);

        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0.025 ether);
        manager.setPositionManager(pm, ITitanLockerManagerV2.LockKind.INFINITY_CL, true);
        nft.approve(address(manager), tokenId);
        vm.deal(address(this), 1 ether);

        uint40 maturity = uint40(block.timestamp + 100);
        manager.createPositionLock{value: 0.025 ether}(pm, tokenId, maturity);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(nft.ownerOf(tokenId), address(locker));
        (bool hasData, , address token1) = locker.getUnderlyingTokens();
        assertTrue(hasData);
        assertTrue(token1 != address(0));
        vm.expectRevert();
        locker.withdrawTo(address(this));
        locker.collectFees();
        assertEq(nft.ownerOf(tokenId), address(locker));
        vm.warp(maturity);
        locker.withdrawTo(address(this));
        assertEq(nft.ownerOf(tokenId), address(this));
    }

    function testSushiV4ClRealPositionLifecycle() public { _testInfinityClLifecycle(SUSHI_V4_CL, 2); }
    function testPancakeInfinityClRealPositionLifecycle() public { _testInfinityClLifecycle(PANCAKE_INFINITY_CL, 2); }

    function testSushiClContractOwnerCanRedirectNativeFees() public {
        IERC721 nft = IERC721(SUSHI_V4_CL);
        uint256 tokenId = 2;
        address originalOwner = nft.ownerOf(tokenId);
        vm.prank(originalOwner);
        nft.transferFrom(originalOwner, address(this), tokenId);
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0.025 ether);
        manager.setPositionManager(SUSHI_V4_CL, ITitanLockerManagerV2.LockKind.INFINITY_CL, true);
        nft.approve(address(manager), tokenId);
        vm.deal(address(this), 1 ether);
        uint40 maturity = uint40(block.timestamp + 100);
        manager.createPositionLock{value: 0.025 ether}(SUSHI_V4_CL, tokenId, maturity);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        RejectNativeOwner owner = new RejectNativeOwner();
        locker.transferOwnership(address(owner));
        owner.claimTo(locker, address(this));
        assertEq(nft.ownerOf(tokenId), address(locker));
        vm.warp(maturity);
        owner.withdrawTo(locker, address(this));
        assertEq(nft.ownerOf(tokenId), address(this));
    }

    function testInfinityManagersNotAccidentallyAllowedAsUniswapV4() public {
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        assertGt(SUSHI_V4_CL.code.length, 0);
        assertGt(PANCAKE_INFINITY_CL.code.length, 0);
        (, bool sushiAllowed) = manager.positionManagerKind(SUSHI_V4_CL);
        (, bool pancakeAllowed) = manager.positionManagerKind(PANCAKE_INFINITY_CL);
        assertFalse(sushiAllowed);
        assertFalse(pancakeAllowed);
    }
}
