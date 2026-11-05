// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

contract ElysiumMainnetForkSmoke is Test {
    function testElysiumMainnetFeePathsAndCustodyLifecycle() public {
        assertEq(block.chainid, 99901, "wrong Elysium network");
        address payable receiver = payable(address(0xFEE));
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(receiver);
        manager.setEthFee(1 ether);
        manager.setTokenFeeBps(500);
        TestERC20 token = new TestERC20("Fork token", "FRK", 1000);
        token.approve(address(manager), type(uint256).max);
        vm.deal(address(this), 2 ether);

        uint40 start = uint40(block.timestamp + 10);
        uint40 end = uint40(block.timestamp + 100);
        manager.createTokenLock{value: 1 ether}(address(token), 100 ether, end, 0);
        TitanLockerV2 tokenLock = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(token.balanceOf(address(tokenLock)), 100 ether);
        assertEq(receiver.balance, 1 ether);

        manager.createVestingLock(address(token), 100 ether, start, start, end, 500);
        TitanLockerV2 vesting = TitanLockerV2(payable(manager.getTokenLockAddress(1)));
        assertEq(token.balanceOf(address(vesting)), 95 ether);
        assertEq(token.balanceOf(receiver), 5 ether);

        vm.expectRevert();
        tokenLock.withdrawTo(address(0xB0B));
        vm.warp(end);
        tokenLock.withdrawTo(address(0xB0B));
        assertEq(token.balanceOf(address(0xB0B)), 100 ether);
        assertEq(vesting.release(), 95 ether);
        assertEq(token.balanceOf(address(vesting)), 0);
    }
}
