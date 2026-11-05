// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {MockERC721Base} from "../../contracts/test/MockERC721Base.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";
import {PoolKeyV4, ActionsV4} from "../../contracts/interfaces/IPositionManagerV4.sol";
import {Ownable} from "../../contracts/Ownable.sol";
import {TitanLockerManagerV1} from "../../contracts/TitanLockerManagerV1.sol";
import {TitanLockerV1} from "../../contracts/TitanLockerV1.sol";

contract HookDataRequiredPositionManager is MockERC721Base {
    error HookDataMissing();

    bool public claimed;

    function mint(address to) external {
        _mint(to, 1);
    }

    function getPoolAndPositionInfo(uint256) external pure returns (PoolKeyV4 memory key, uint256 info) {
        key = PoolKeyV4(address(0), address(0), 3000, 60, address(0xB00C));
        info = 0;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(uint8(actions[0]) == ActionsV4.DECREASE_LIQUIDITY);
        (uint256 tokenId, , , , bytes memory hookData) = abi.decode(
            params[0], (uint256, uint256, uint128, uint128, bytes)
        );
        require(ownerOf(tokenId) == msg.sender);
        if (hookData.length == 0) revert HookDataMissing();
        claimed = true;
    }
}

contract AuditTitanV21 is Test {
    TitanLockerManagerV2 manager;
    TestERC20 token;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setUp() public {
        vm.warp(100);
        manager = new TitanLockerManagerV2(payable(address(this)));
        manager.setTokenFeeBps(300);
        token = new TestERC20("Test", "TST", 1000);
        token.approve(address(manager), type(uint256).max);
    }

    function testVestingSurplusRecoveryPreservesGrant() public {
        manager.createVestingLock(address(token), 100 ether, 110, 110, 200, 300);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(token.balanceOf(address(locker)), 97 ether);

        token.transfer(address(locker), 20 ether);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, uint40(200)));
        locker.withdrawVestingSurplus();
        vm.warp(201);
        assertEq(locker.withdrawVestingSurplus(), 20 ether);
        assertEq(token.balanceOf(address(locker)), 97 ether);
        assertEq(locker.release(), 97 ether);
        assertEq(token.balanceOf(address(locker)), 0);
        assertEq(locker.releasable(), 0);
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        locker.withdrawToken(address(token));
        vm.expectRevert(TitanLockerV2.WrongLockKind.selector);
        locker.withdraw();
    }

    function testOneUnitCannotCreateZeroBalanceLock() public {
        vm.expectRevert(TitanLockerManagerV2.ZeroAmount.selector);
        manager.createTokenLock(address(token), 1, 200, 300);
        assertEq(manager.tokenLockerCount(), 0);
    }

    function testOneUnitCannotCreateZeroGrantVestingLock() public {
        vm.expectRevert(TitanLockerManagerV2.ZeroAmount.selector);
        manager.createVestingLock(address(token), 1, 110, 110, 200, 300);
        assertEq(manager.tokenLockerCount(), 0);
    }

    function testUnsolicitedOwnershipPollutesVictimIndex() public {
        address attacker = address(0xA11CE);
        address victim = address(0xB0B);
        token.transfer(attacker, 20);

        vm.startPrank(attacker);
        token.approve(address(manager), type(uint256).max);
        for (uint256 i; i < 8; ++i) {
            manager.createTokenLock(address(token), 2, 200, 300);
            TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(uint40(i))));
            assertEq(token.balanceOf(address(locker)), 1);
            locker.transferOwnership(victim);
        }
        vm.stopPrank();

        uint40[] memory ids = manager.getTokenLockersForAddress(victim);
        assertEq(ids.length, 8);
        for (uint256 i; i < ids.length; ++i) {
            (, , , address lockOwner, , , , , , uint256 balance) = manager.getTokenLockData(ids[i]);
            assertEq(lockOwner, victim);
            assertEq(balance, 1);
        }
    }

    function testV4FeeClaimCanSupplyRequiredHookData() public {
        HookDataRequiredPositionManager pm = new HookDataRequiredPositionManager();
        pm.mint(address(this));
        pm.approve(address(manager), 1);
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV4, true);
        manager.setEthFee(0);
        manager.createPositionLock(address(pm), 1, 200);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));

        vm.expectRevert(HookDataRequiredPositionManager.HookDataMissing.selector);
        locker.collectFees();
        locker.collectFeesWithHookData(hex"01");
        assertTrue(pm.claimed());

        vm.warp(201);
        locker.withdraw();
        assertEq(pm.ownerOf(1), address(this));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(uint256(1), uint256(0), uint128(0), uint128(0), hex"01");
        pm.modifyLiquidities(abi.encode(abi.encodePacked(ActionsV4.DECREASE_LIQUIDITY), params), block.timestamp);
        assertTrue(pm.claimed());
    }

    function testNonOwnerCannotMoveMaturedTokenLock() public {
        manager.createTokenLock(address(token), 100 ether, 200, 300);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        address attacker = address(0xBAD);
        vm.warp(201);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        locker.withdraw();
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        locker.withdrawToken(address(token));
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        locker.transferOwnership(attacker);
        vm.stopPrank();

        assertEq(token.balanceOf(address(locker)), 97 ether);
        locker.withdraw();
        assertEq(token.balanceOf(address(locker)), 0);
    }

    function testNonOwnerCannotReleaseMaturedVestingGrant() public {
        manager.createVestingLock(address(token), 100 ether, 110, 110, 200, 300);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        address attacker = address(0xBAD);
        vm.warp(201);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        locker.release();

        assertEq(token.balanceOf(address(locker)), 97 ether);
        assertEq(locker.release(), 97 ether);
        assertEq(token.balanceOf(address(locker)), 0);
    }

    function testLegacyV1NonOwnerCannotWithdrawMaturedLock() public {
        TitanLockerManagerV1 legacy = new TitanLockerManagerV1(payable(address(this)));
        token.approve(address(legacy), type(uint256).max);
        legacy.createTokenLocker(address(token), 100 ether, 200);
        TitanLockerV1 locker = TitanLockerV1(payable(legacy.getTokenLockAddress(0)));
        address attacker = address(0xBAD);
        vm.warp(201);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        locker.withdraw();
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        locker.withdrawToken(address(token));
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, attacker));
        locker.transferOwnership(attacker);
        vm.stopPrank();

        assertEq(token.balanceOf(address(locker)), 95 ether);
        locker.withdraw();
        assertEq(token.balanceOf(address(locker)), 0);
    }
}
