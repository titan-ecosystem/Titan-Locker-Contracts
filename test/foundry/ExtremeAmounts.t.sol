// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";

contract HugeSupplyToken is ERC20 {
    constructor(uint256 supply) ERC20("Huge supply", "HUGE") {
        _mint(msg.sender, supply);
    }
}

contract ExtremeAmountsTest is Test {
    function testVeryLargeTokenFeeDoesNotOverflow() public {
        vm.warp(100);
        uint256 amount = type(uint256).max / 2;
        HugeSupplyToken token = new HugeSupplyToken(amount);
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        token.approve(address(manager), amount);
        manager.createTokenLock(address(token), amount, 200, 500);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        uint256 expectedFee = amount / 20 + (amount % 20 == 0 ? 0 : 1);
        assertEq(token.balanceOf(address(0xFEE)), expectedFee);
        assertEq(token.balanceOf(address(locker)), amount - expectedFee);
    }

    function testVeryLargeVestingGrantRemainsClaimableBeforeEnd() public {
        vm.warp(100);
        uint256 amount = type(uint256).max / 2;
        HugeSupplyToken token = new HugeSupplyToken(amount);
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0.025 ether);
        token.approve(address(manager), amount);
        vm.deal(address(this), 1 ether);
        manager.createVestingLock{value: 0.025 ether}(address(token), amount, 110, 110, 210, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        vm.warp(160);
        assertEq(locker.vestedAmount(), amount / 2);
        assertEq(locker.release(), amount / 2);
        vm.warp(210);
        assertEq(locker.release(), amount - amount / 2);
        assertEq(token.balanceOf(address(locker)), 0);
    }
}
