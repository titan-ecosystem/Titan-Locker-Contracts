// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {MockNonfungiblePositionManagerV3} from "../../contracts/test/MockNonfungiblePositionManagerV3.sol";
import {MockPositionManagerV4} from "../../contracts/test/MockPositionManagerV4.sol";
import {MockUniswapV2Pair} from "../../contracts/test/MockUniswapV2Pair.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";
import {Ownable} from "../../contracts/Ownable.sol";

contract RejectEthFee {
    receive() external payable { revert("fee rejected"); }
}

contract AuditEndToEnd is Test {
    TitanLockerManagerV2 manager;
    TestERC20 token0;
    TestERC20 token1;
    address payable feeReceiver = payable(address(0xFEE));
    address bob = address(0xB0B);

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setUp() public {
        vm.warp(100);
        vm.deal(address(this), 10 ether);
        manager = new TitanLockerManagerV2(feeReceiver);
        manager.setEthFee(0.025 ether);
        manager.setTokenFeeBps(300);
        token0 = new TestERC20("Token 0", "T0", 1000);
        token1 = new TestERC20("Token 1", "T1", 1000);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
    }

    function _tokenLock(uint256 amount) private returns (TitanLockerV2) {
        manager.createTokenLock(address(token0), amount, 200, 300);
        return TitanLockerV2(payable(manager.getTokenLockAddress(manager.tokenLockerCount() - 1)));
    }

    function testTokenFeeCeilingAndAccountingEndToEnd() public {
        uint256 beforeOwner = token0.balanceOf(address(this));
        TitanLockerV2 locker = _tokenLock(101);
        assertEq(token0.balanceOf(address(this)), beforeOwner - 101);
        assertEq(token0.balanceOf(feeReceiver), 4);
        assertEq(token0.balanceOf(address(locker)), 97);
        assertEq(manager.tokenLockerCount(), 1);
        (,,,,,,,,, uint256 reportedBalance) = manager.getTokenLockData(0);
        assertEq(reportedBalance, 97);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, uint40(200)));
        locker.withdraw();
        vm.warp(200);
        locker.withdraw();
        assertEq(token0.balanceOf(address(locker)), 0);
        assertEq(token0.balanceOf(address(this)), beforeOwner - 4);
    }

    function testEthFeeTopUpExtensionOwnershipAndWithdrawalEndToEnd() public {
        uint256 feeBefore = feeReceiver.balance;
        manager.createTokenLock{value: 0.025 ether}(address(token0), 100 ether, 200, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(feeReceiver.balance - feeBefore, 0.025 ether);
        assertEq(token0.balanceOf(address(locker)), 100 ether);

        token0.approve(address(locker), 20 ether);
        locker.deposit(20 ether, 250);
        assertEq(token0.balanceOf(address(locker)), 120 ether);
        (,,,,,,,, uint40 unlockTime,) = locker.getLockData();
        assertEq(unlockTime, 250);
        vm.expectRevert(TitanLockerV2.UnlockTimeCannotBeReduced.selector);
        locker.extendLock(249);

        locker.transferOwnership(bob);
        assertEq(locker.owner(), bob);
        assertEq(manager.getTokenLockersForAddress(bob).length, 1);
        assertEq(manager.getTokenLockersForAddress(address(this)).length, 1); // permanent creator index
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, address(this)));
        locker.withdraw();
        vm.warp(251);
        vm.prank(bob);
        locker.withdraw();
        assertEq(token0.balanceOf(bob), 120 ether);
    }

    function testFeeSlippageCapAndAdminFeeLimitRollback() public {
        uint256 beforeOwner = token0.balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(TitanLockerManagerV2.TokenFeeExceedsCallerMax.selector, uint16(300), uint16(299)));
        manager.createTokenLock(address(token0), 100 ether, 200, 299);
        assertEq(manager.tokenLockerCount(), 0);
        assertEq(token0.balanceOf(address(this)), beforeOwner);
        vm.expectRevert(TitanLockerManagerV2.TokenFeeTooHigh.selector);
        manager.setTokenFeeBps(501);
        assertEq(manager.tokenFeeBps(), 300);
        manager.setTokenFeeBps(500);
        assertEq(manager.tokenFeeBps(), 500);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerManagerV2.TokenFeeExceedsCallerMax.selector, uint16(500), uint16(300)));
        manager.createVestingLock(address(token0), 100 ether, 110, 110, 200, 300);
        assertEq(manager.tokenLockerCount(), 0);
    }

    function testFeeExemptionAndNoEthForExemptCreator() public {
        manager.setFeeExempt(address(this), true);
        assertTrue(manager.isExemptFromFees(address(this)));
        vm.expectRevert(TitanLockerManagerV2.ExemptAccountsPayNoEth.selector);
        manager.createTokenLock{value: 0.025 ether}(address(token0), 100 ether, 200, 300);
        TitanLockerV2 locker = _tokenLock(100 ether);
        assertEq(token0.balanceOf(address(locker)), 100 ether);
        assertEq(token0.balanceOf(feeReceiver), 0);
        assertEq(feeReceiver.balance, 0);
    }

    function testWrongEthFeeAndRejectingReceiverRollBack() public {
        vm.expectRevert(abi.encodeWithSelector(TitanLockerManagerV2.IncorrectEthFee.selector, 0.025 ether, 0.024 ether));
        manager.createTokenLock{value: 0.024 ether}(address(token0), 100 ether, 200, 0);
        RejectEthFee reject = new RejectEthFee();
        manager.setFeeReceiver(payable(address(reject)));
        uint256 beforeOwner = token0.balanceOf(address(this));
        vm.expectRevert(TitanLockerManagerV2.EthTransferFailed.selector);
        manager.createTokenLock{value: 0.025 ether}(address(token0), 100 ether, 200, 0);
        assertEq(manager.tokenLockerCount(), 0);
        assertEq(token0.balanceOf(address(this)), beforeOwner);
    }

    function testCreationDisabledBlocksEveryNewKindButExistingLockWorks() public {
        TitanLockerV2 locker = _tokenLock(100 ether);
        manager.setCreationEnabled(false);
        vm.expectRevert(TitanLockerManagerV2.CreationDisabled.selector);
        manager.createTokenLock(address(token0), 100 ether, 200, 300);
        vm.expectRevert(TitanLockerManagerV2.CreationDisabled.selector);
        manager.createVestingLock(address(token0), 100 ether, 110, 110, 200, 300);
        vm.expectRevert(TitanLockerManagerV2.CreationDisabled.selector);
        manager.createPositionLock(address(0x123), 1, 200);
        token0.approve(address(locker), 10 ether);
        locker.deposit(10 ether, 0);
        vm.warp(200);
        locker.withdraw();
        assertEq(token0.balanceOf(address(locker)), 0);
    }

    function testAdminAuthorizationAndValidation() public {
        assertTrue(manager.creationEnabled());
        assertEq(manager.feeReceiver(), feeReceiver);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        manager.setEthFee(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        manager.setTokenFeeBps(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        manager.setFeeReceiver(payable(bob));
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        manager.setFeeExempt(bob, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        manager.setCreationEnabled(false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        manager.setPositionManager(address(0x123), ITitanLockerManagerV2.LockKind.UNIV4, true);
        vm.stopPrank();
        vm.expectRevert(Ownable.ZeroAddress.selector);
        manager.setFeeReceiver(payable(address(0)));
        vm.expectRevert(Ownable.ZeroAddress.selector);
        manager.setPositionManager(address(0), ITitanLockerManagerV2.LockKind.UNIV4, true);
        vm.expectRevert(TitanLockerManagerV2.InvalidPositionManagerKind.selector);
        manager.setPositionManager(address(0x123), ITitanLockerManagerV2.LockKind.ERC20, true);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerManagerV2.CallerIsNotLocker.selector, uint40(0), address(this)));
        manager.notifyLockerOwnerChange(0, bob, address(this), address(this));
        manager.setPositionManager(address(0x123), ITitanLockerManagerV2.LockKind.UNIV4, true);
        (ITitanLockerManagerV2.LockKind kind, bool allowed) = manager.positionManagerKind(address(0x123));
        assertEq(uint256(kind), uint256(ITitanLockerManagerV2.LockKind.UNIV4));
        assertTrue(allowed);
    }

    function testStrayAssetRescueAndLockedAssetGuards() public {
        TitanLockerV2 locker = _tokenLock(100 ether);
        token1.transfer(address(locker), 10 ether);
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        locker.withdrawToken(address(token0));
        locker.withdrawToken(address(token1));
        assertEq(token1.balanceOf(address(locker)), 0);

        MockNonfungiblePositionManagerV3 stray = new MockNonfungiblePositionManagerV3();
        uint256 id = stray.mint(address(this), address(token0), address(token1), 0, 0);
        stray.safeTransferFrom(address(this), address(locker), id);
        locker.withdrawNft(address(stray), id);
        assertEq(stray.ownerOf(id), address(this));

        (bool sent,) = payable(address(locker)).call{value: 1 ether}("");
        assertTrue(sent);
        uint256 ethBefore = address(this).balance;
        locker.withdrawEth();
        assertEq(address(this).balance - ethBefore, 1 ether);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        locker.withdrawToken(address(token1));
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        locker.withdrawNft(address(stray), id);
        vm.expectRevert(abi.encodeWithSelector(Ownable.CallerNotOwner.selector, bob));
        locker.withdrawEth();
        vm.stopPrank();
    }

    function testVestingLifecycleAndNonVestingFunctionGuards() public {
        manager.createVestingLock{value: 0.025 ether}(address(token0), 100 ether, 110, 120, 210, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(uint256(locker.getKind()), uint256(ITitanLockerManagerV2.LockKind.ERC20_VESTING));
        assertEq(locker.releasable(), 0);
        vm.expectRevert(TitanLockerV2.WrongLockKind.selector);
        locker.withdraw();
        vm.expectRevert(TitanLockerV2.WrongLockKind.selector);
        locker.deposit(1, 0);
        vm.expectRevert(TitanLockerV2.WrongLockKind.selector);
        locker.extendLock(220);
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        locker.withdrawToken(address(token0));
        vm.warp(120);
        assertEq(locker.releasable(), 10 ether);
        assertEq(locker.release(), 10 ether);
        locker.transferOwnership(bob);
        vm.warp(210);
        vm.prank(bob);
        assertEq(locker.release(), 90 ether);
        assertEq(locker.releasedAmount(), 100 ether);
        assertEq(token0.balanceOf(address(locker)), 0);
        assertEq(token0.balanceOf(bob), 90 ether);
    }

    function testV3PositionLifecycleFeeAccrualAndNftGuard() public {
        MockNonfungiblePositionManagerV3 pm = new MockNonfungiblePositionManagerV3();
        uint256 id = pm.mint(address(this), address(token0), address(token1), 4 ether, 7 ether);
        token0.transfer(address(pm), 10 ether);
        token1.transfer(address(pm), 10 ether);
        pm.approve(address(manager), id);
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV3, true);
        manager.createPositionLock{value: 0.025 ether}(address(pm), id, 200);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertEq(pm.ownerOf(id), address(locker));
        (bool hasData, address a, address b) = locker.getUnderlyingTokens();
        assertTrue(hasData);
        assertEq(a, address(token0));
        assertEq(b, address(token1));
        assertEq(manager.getTokenLockersForAddress(address(token0)).length, 1);
        vm.expectRevert(TitanLockerV2.CannotSweepLockedToken.selector);
        locker.withdrawNft(address(pm), id);
        (uint256 fee0, uint256 fee1) = locker.collectFees();
        assertEq(fee0, 4 ether);
        assertEq(fee1, 7 ether);
        pm.setOwed(id, 2 ether, 1 ether);
        (fee0, fee1) = locker.collectFees();
        assertEq(fee0, 2 ether);
        assertEq(fee1, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, uint40(200)));
        locker.withdraw();
        vm.warp(200);
        locker.withdraw();
        assertEq(pm.ownerOf(id), address(this));
    }

    function testV4PositionNativeFeeLifecycleAndAllowlistRemoval() public {
        MockPositionManagerV4 pm = new MockPositionManagerV4();
        uint256 id = pm.mint(address(this), address(0), address(token0), 0.1 ether, 5 ether);
        vm.deal(address(pm), 0.1 ether);
        token0.transfer(address(pm), 5 ether);
        pm.approve(address(manager), id);
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV4, true);
        manager.createPositionLock{value: 0.025 ether}(address(pm), id, 200);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV4, false);
        assertEq(pm.ownerOf(id), address(locker));
        uint256 ethBefore = address(this).balance;
        (uint256 fee0, uint256 fee1) = locker.collectFees();
        assertEq(fee0, 0.1 ether);
        assertEq(fee1, 5 ether);
        assertEq(address(this).balance - ethBefore, 0.1 ether);
        vm.warp(200);
        locker.withdraw();
        assertEq(pm.ownerOf(id), address(this));
        vm.expectRevert(abi.encodeWithSelector(TitanLockerManagerV2.PositionManagerNotAllowed.selector, address(pm)));
        manager.createPositionLock{value: 0.025 ether}(address(pm), id, 300);
    }

    function testPositionFeeRequirementAndExemptionEndToEnd() public {
        MockPositionManagerV4 pm = new MockPositionManagerV4();
        uint256 id = pm.mint(address(this), address(token0), address(token1), 0, 0);
        pm.approve(address(manager), id);
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV4, true);
        vm.expectRevert(abi.encodeWithSelector(TitanLockerManagerV2.IncorrectEthFee.selector, 0.025 ether, 0));
        manager.createPositionLock(address(pm), id, 200);
        assertEq(manager.tokenLockerCount(), 0);
        assertEq(pm.ownerOf(id), address(this));

        manager.setFeeExempt(address(this), true);
        vm.expectRevert(TitanLockerManagerV2.ExemptAccountsPayNoEth.selector);
        manager.createPositionLock{value: 0.025 ether}(address(pm), id, 200);
        manager.createPositionLock(address(pm), id, 200);
        assertEq(manager.tokenLockerCount(), 1);
        assertEq(pm.ownerOf(id), manager.getTokenLockAddress(0));
    }

    function testRejectingPositionFeeReceiverRollsBackNftCustody() public {
        MockNonfungiblePositionManagerV3 pm = new MockNonfungiblePositionManagerV3();
        uint256 id = pm.mint(address(this), address(token0), address(token1), 0, 0);
        pm.approve(address(manager), id);
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV3, true);
        RejectEthFee reject = new RejectEthFee();
        manager.setFeeReceiver(payable(address(reject)));
        vm.expectRevert(TitanLockerManagerV2.EthTransferFailed.selector);
        manager.createPositionLock{value: 0.025 ether}(address(pm), id, 200);
        assertEq(manager.tokenLockerCount(), 0);
        assertEq(pm.ownerOf(id), address(this));
    }

    function testOwnershipIndexMovesWithoutLosingCreatorSearch() public {
        TitanLockerV2 locker = _tokenLock(100 ether);
        address carol = address(0xCA701);
        locker.transferOwnership(bob);
        vm.prank(bob);
        locker.transferOwnership(carol);
        assertEq(locker.owner(), carol);
        assertEq(manager.getTokenLockersForAddress(bob).length, 0);
        assertEq(manager.getTokenLockersForAddress(carol).length, 1);
        assertEq(manager.getTokenLockersForAddress(address(this)).length, 1);
        vm.startPrank(carol);
        vm.expectRevert(Ownable.ZeroAddress.selector);
        locker.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(locker.owner(), carol);
    }

    function testLpTokenLockIndexesUnderlyingAndWithdrawsAfterUnlock() public {
        MockUniswapV2Pair lp = new MockUniswapV2Pair(address(token0), address(token1), 2, 3, 100 ether);
        token0.transfer(address(lp), 12 ether);
        token1.transfer(address(lp), 13 ether);
        lp.approve(address(manager), type(uint256).max);
        manager.createTokenLock{value: 0.025 ether}(address(lp), 10 ether, 200, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        (bool hasData, address a, address b) = locker.getUnderlyingTokens();
        assertTrue(hasData);
        assertEq(a, address(token0));
        assertEq(b, address(token1));
        assertEq(manager.getTokenLockersForAddress(address(token0)).length, 1);
        assertEq(manager.getTokenLockersForAddress(address(token1)).length, 1);
        assertEq(lp.balanceOf(address(locker)), 10 ether);
        vm.warp(200);
        locker.withdraw();
        assertEq(lp.balanceOf(address(locker)), 0);
    }

    function testInvalidSchedulesZeroAmountsAndPastUnlockRollback() public {
        vm.expectRevert(TitanLockerManagerV2.ZeroAmount.selector);
        manager.createTokenLock(address(token0), 0, 200, 300);
        vm.expectRevert(TitanLockerManagerV2.ZeroAmount.selector);
        manager.createVestingLock(address(token0), 0, 110, 110, 200, 300);
        vm.expectRevert(TitanLockerManagerV2.InvalidVestingSchedule.selector);
        manager.createVestingLock(address(token0), 1 ether, 200, 200, 200, 300);
        vm.expectRevert(TitanLockerManagerV2.InvalidVestingSchedule.selector);
        manager.createVestingLock(address(token0), 1 ether, 110, 109, 200, 300);
        vm.expectRevert(TitanLockerManagerV2.InvalidVestingSchedule.selector);
        manager.createVestingLock(address(token0), 1 ether, 110, 201, 200, 300);
        vm.expectRevert(TitanLockerManagerV2.InvalidVestingSchedule.selector);
        manager.createVestingLock(address(token0), 1 ether, 90, 90, 100, 300);
        vm.expectRevert(TitanLockerV2.UnlockTimeNotInFuture.selector);
        manager.createTokenLock(address(token0), 1 ether, 100, 300);
        assertEq(manager.tokenLockerCount(), 0);
    }
}
