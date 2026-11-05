// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV1} from "../../contracts/TitanLockerManagerV1.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {MockNonfungiblePositionManagerV3} from "../../contracts/test/MockNonfungiblePositionManagerV3.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";

contract FeeFindingReproductions is Test {
    address payable internal feeReceiver = payable(address(0xFEE));

    function setUp() public { vm.warp(100); }

    function testLegacyV1CanChargeEntireDepositAfterFeeIncrease() public {
        TitanLockerManagerV1 manager = new TitanLockerManagerV1(feeReceiver);
        TestERC20 token = new TestERC20("Fee token", "FEE", 1000);
        token.approve(address(manager), 1000);

        // This simulates the owner changing the live fee before a user's
        // pending creation is mined. V1 has no caller fee ceiling.
        manager.setTokenFeeBps(10_000);
        manager.createTokenLocker(address(token), 1000, 200);

        assertEq(token.balanceOf(feeReceiver), 1000);
        assertEq(token.balanceOf(manager.getTokenLockAddress(0)), 0);
    }

    function testZeroFlatFeeHasDifferentPositionAndTokenBehavior() public {
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(feeReceiver);
        manager.setEthFee(0);
        manager.setTokenFeeBps(300);
        TestERC20 token = new TestERC20("Fee token", "FEE", 1000);
        token.approve(address(manager), 100);
        manager.createTokenLock(address(token), 100, 200, 300);
        assertEq(token.balanceOf(feeReceiver), 3);
        assertEq(token.balanceOf(manager.getTokenLockAddress(0)), 97);

        MockNonfungiblePositionManagerV3 positionManager = new MockNonfungiblePositionManagerV3();
        manager.setPositionManager(address(positionManager), ITitanLockerManagerV2.LockKind.UNIV3, true);
        uint256 positionId = positionManager.mint(address(this), address(0xA), address(0xB), 0, 0);
        positionManager.approve(address(manager), positionId);
        manager.createPositionLock(address(positionManager), positionId, 200);
        assertEq(positionManager.ownerOf(positionId), manager.getTokenLockAddress(1));
        assertEq(feeReceiver.balance, 0);
    }

    function testTinyOpeningThenFeeFreeTopUpFollowsPublishedFeePolicy() public {
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(feeReceiver);
        manager.setTokenFeeBps(300);
        TestERC20 token = new TestERC20("Fee token", "FEE", 1000);
        token.approve(address(manager), 2);
        manager.createTokenLock(address(token), 2, 200, 300);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(token.balanceOf(feeReceiver), 1);
        assertEq(token.balanceOf(address(locker)), 1);

        token.approve(address(locker), 998);
        locker.deposit(998, 0);
        assertEq(token.balanceOf(feeReceiver), 1);
        assertEq(token.balanceOf(address(locker)), 999);
    }
}
