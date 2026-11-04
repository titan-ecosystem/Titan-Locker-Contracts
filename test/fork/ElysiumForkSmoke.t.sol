// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ElysiumForkSmoke is Test {
    address constant USDC = 0x7D29d8047B905000459c0E80c34a26CeedcB47b2;

    function testTokenAndVestingLifecycleOnKinetiqTestnetFork() public {
        assertEq(block.chainid, 99801, "wrong Elysium network");

        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0.025 ether);
        manager.setTokenFeeBps(300);
        TestERC20 token = new TestERC20("Fork Token", "FRK", 1_000_000);
        token.approve(address(manager), type(uint256).max);
        vm.deal(address(this), 1 ether);
        uint256 receiverNativeBefore = address(0xFEE).balance;

        uint40 start = uint40(block.timestamp + 100);
        uint40 end = uint40(block.timestamp + 300);
        manager.createTokenLock{value: 0.025 ether}(address(token), 100 ether, end, 0);
        TitanLockerV2 tokenLock = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(token.balanceOf(address(tokenLock)), 100 ether);
        assertEq(address(0xFEE).balance - receiverNativeBefore, 0.025 ether);

        manager.createVestingLock(address(token), 100 ether, start, start, end, 300);
        TitanLockerV2 vestingLock = TitanLockerV2(payable(manager.getTokenLockAddress(1)));
        assertEq(token.balanceOf(address(vestingLock)), 97 ether);
        assertEq(token.balanceOf(address(0xFEE)), 3 ether);

        vm.expectRevert();
        tokenLock.withdraw();
        vm.warp(end);
        tokenLock.withdraw();
        assertEq(token.balanceOf(address(tokenLock)), 0);
        assertEq(vestingLock.release(), 97 ether);
        assertEq(token.balanceOf(address(vestingLock)), 0);
    }

    function testCanonicalElysiumUsdcLockAndFeeOnFork() public {
        assertEq(block.chainid, 99801, "wrong Elysium network");
        assertGt(USDC.code.length, 0, "canonical USDC missing");

        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setTokenFeeBps(300);
        IERC20 usdc = IERC20(USDC);
        deal(USDC, address(this), 100_000_000);
        usdc.approve(address(manager), 100_000_000);

        uint40 end = uint40(block.timestamp + 300);
        uint256 feeBefore = usdc.balanceOf(address(0xFEE));
        manager.createTokenLock(USDC, 100_000_000, end, 300);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(usdc.balanceOf(address(locker)), 97_000_000);
        assertEq(usdc.balanceOf(address(0xFEE)) - feeBefore, 3_000_000);
        vm.expectRevert();
        locker.withdraw();
        vm.warp(end);
        locker.withdraw();
        assertEq(usdc.balanceOf(address(this)), 97_000_000);
    }
}
