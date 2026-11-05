// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {MockNonfungiblePositionManagerV3} from "../../contracts/test/MockNonfungiblePositionManagerV3.sol";
import {MockERC721Base} from "../../contracts/test/MockERC721Base.sol";
import {Ownable} from "../../contracts/Ownable.sol";

/// @dev Deliberately lacks onERC721Received and can hand over only to `project`.
contract FixedProjectHandover {
    address public immutable project;
    TitanLockerV2 public locker;

    constructor(address project_) { project = project_; }

    function createPositionLock(TitanLockerManagerV2 manager, MockNonfungiblePositionManagerV3 pm, uint256 id) external {
        pm.approve(address(manager), id);
        manager.createPositionLock(address(pm), id, 200);
        locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
    }

    function withdraw() external { locker.withdraw(); }
    function handover() external { locker.transferOwnership(project); }
}

contract OwnerHandoverHardening is Test {
    function _hasId(uint40[] memory ids, uint40 id) internal pure returns (bool) {
        for (uint256 i; i < ids.length; i++) if (ids[i] == id) return true;
        return false;
    }

    function testUnsolicitedIndexEntriesCannotBlockFixedProjectHandover() public {
        vm.warp(100);
        address project = address(0xB0B);
        address attacker = address(0xA11CE);
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(this)));
        manager.setEthFee(0);
        manager.setTokenFeeBps(300);
        MockNonfungiblePositionManagerV3 pm = new MockNonfungiblePositionManagerV3();
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV3, true);
        FixedProjectHandover fixedOwner = new FixedProjectHandover(project);
        uint256 positionId = pm.mint(address(fixedOwner), address(0xA), address(0xB), 0, 0);
        fixedOwner.createPositionLock(manager, pm, positionId);
        TitanLockerV2 locker = fixedOwner.locker();

        TestERC20 token = new TestERC20("Index spam", "IDX", 1000);
        token.transfer(attacker, 800);
        vm.startPrank(attacker);
        token.approve(address(manager), type(uint256).max);
        for (uint40 i = 0; i < 300; i++) {
            manager.createTokenLock(address(token), 2, 200, 300);
            TitanLockerV2 dust = TitanLockerV2(payable(manager.getTokenLockAddress(i + 1)));
            dust.transferOwnership(project);
        }
        vm.stopPrank();
        vm.warp(200);
        vm.expectRevert(MockERC721Base.TransferToNonReceiver.selector);
        fixedOwner.withdraw();
        assertEq(pm.ownerOf(positionId), address(locker));

        // The attacker and project handover occur in separate transactions.
        vm.cool(address(manager));
        uint256 gasBefore = gasleft();
        (bool ok, ) = address(fixedOwner).call{gas: 120_000}(abi.encodeCall(FixedProjectHandover.handover, ()));
        emit log_named_uint("handover gas used", gasBefore - gasleft());
        assertTrue(ok, "handover should not scan the attacker-grown project bucket");
        assertEq(manager.getTokenLockersForAddress(project).length, 301);
        assertEq(locker.owner(), project);
        address finalOwner = address(0xF1A1);
        vm.cool(address(manager));
        vm.prank(project);
        (bool onward, ) = address(locker).call{gas: 120_000}(
            abi.encodeWithSelector(Ownable.transferOwnership.selector, finalOwner)
        );
        assertTrue(onward, "handover should not scan the old owner's bucket");
        assertEq(manager.getTokenLockersForAddress(project).length, 300);
        vm.prank(finalOwner);
        locker.withdraw();
        assertEq(pm.ownerOf(positionId), finalOwner);
    }

    function testOwnerCanChoosePositionRecipientOnlyAfterUnlock() public {
        vm.warp(100);
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(this)));
        manager.setEthFee(0);
        MockNonfungiblePositionManagerV3 pm = new MockNonfungiblePositionManagerV3();
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV3, true);
        uint256 id = pm.mint(address(this), address(0xA), address(0xB), 0, 0);
        pm.approve(address(manager), id);
        manager.createPositionLock(address(pm), id, 200);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        address recipient = address(0xB0B);

        vm.expectRevert(abi.encodeWithSelector(TitanLockerV2.LockStillActive.selector, uint40(200)));
        locker.withdrawTo(recipient);
        vm.expectRevert(Ownable.ZeroAddress.selector);
        locker.withdrawTo(address(0));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        locker.withdrawTo(recipient);
        assertEq(pm.ownerOf(id), address(locker));

        vm.warp(200);
        locker.withdrawTo(recipient);
        assertEq(pm.ownerOf(id), recipient);
        assertEq(locker.owner(), address(this));
    }

    function testOwnerIndexRemovalAndPermanentRolesRemainConsistent() public {
        vm.warp(100);
        TitanLockerManagerV2 manager = new TitanLockerManagerV2(payable(address(this)));
        manager.setTokenFeeBps(0);
        TestERC20 token = new TestERC20("Index", "IDX", 1000);
        token.approve(address(manager), type(uint256).max);
        for (uint40 i; i < 3; i++) manager.createTokenLock(address(token), 10, 200, 0);
        TitanLockerV2 lock0 = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        TitanLockerV2 lock1 = TitanLockerV2(payable(manager.getTokenLockAddress(1)));
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address carol = address(0xCA401);

        lock0.transferOwnership(alice);
        lock1.transferOwnership(alice);
        assertEq(manager.getTokenLockersForAddress(alice).length, 2);
        vm.prank(alice);
        lock0.transferOwnership(bob); // swap-removes lock0 from Alice's bucket
        assertEq(manager.getTokenLockersForAddress(alice).length, 1);
        assertTrue(_hasId(manager.getTokenLockersForAddress(alice), 1));
        vm.prank(alice);
        lock1.transferOwnership(carol); // uses the updated position of lock1
        assertEq(manager.getTokenLockersForAddress(alice).length, 0);
        assertTrue(_hasId(manager.getTokenLockersForAddress(bob), 0));
        assertTrue(_hasId(manager.getTokenLockersForAddress(carol), 1));
        assertEq(manager.getTokenLockersForAddress(address(this)).length, 3); // creator stays indexed
        assertEq(manager.getTokenLockersForAddress(address(token)).length, 3); // asset stays indexed
    }
}
