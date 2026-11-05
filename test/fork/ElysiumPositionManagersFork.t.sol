// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";

contract ElysiumPositionManagersFork is Test {
    TitanLockerManagerV2 constant TITAN = TitanLockerManagerV2(0x713E56CeE7060F01F710bF26Aff988264dcfb311);
    address constant V3 = 0xF025e0Fe9E331A0eF05c2ad3C4E9C64b625cda6f;
    address constant V4 = 0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518;
    address constant RECIPIENT = address(0xB0B);

    function testV3PositionCustodyFeesAndMaturity() public {
        _exercisePosition(V3, ITitanLockerManagerV2.LockKind.UNIV3, 1);
    }

    function testV4PositionCustodyFeesAndMaturity() public {
        _exercisePosition(V4, ITitanLockerManagerV2.LockKind.UNIV4, 1);
    }

    function _exercisePosition(address pm, ITitanLockerManagerV2.LockKind kind, uint256 tokenId) internal {
        assertEq(block.chainid, 99901, "wrong Elysium network");
        address nftOwner = IERC721(pm).ownerOf(tokenId);
        assertTrue(nftOwner != address(0), "position missing");

        vm.prank(TITAN.owner());
        TITAN.setPositionManager(pm, kind, true);
        vm.deal(nftOwner, 2 ether);
        vm.prank(nftOwner);
        IERC721(pm).approve(address(TITAN), tokenId);

        uint40 lockId = TITAN.tokenLockerCount();
        uint40 unlock = uint40(block.timestamp + 100);
        vm.prank(nftOwner);
        TITAN.createPositionLock{value: 1 ether}(pm, tokenId, unlock);
        TitanLockerV2 lock = TitanLockerV2(payable(TITAN.getTokenLockAddress(lockId)));
        assertEq(IERC721(pm).ownerOf(tokenId), address(lock), "NFT not held by lock");
        (bool hasData, , ) = lock.getUnderlyingTokens();
        assertTrue(hasData, "underlying pair unavailable");

        vm.startPrank(nftOwner);
        lock.collectFeesTo(RECIPIENT);
        vm.expectRevert();
        lock.withdrawTo(RECIPIENT);
        vm.warp(unlock);
        lock.withdrawTo(RECIPIENT);
        vm.stopPrank();
        assertEq(IERC721(pm).ownerOf(tokenId), RECIPIENT, "matured NFT not withdrawn");
    }
}
