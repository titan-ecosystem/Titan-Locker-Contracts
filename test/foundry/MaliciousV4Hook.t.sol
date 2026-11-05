// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";
import {ITitanLockerManagerV2} from "../../contracts/ITitanLockerManagerV2.sol";
import {PoolKeyV4, ActionsV4} from "../../contracts/interfaces/IPositionManagerV4.sol";
import {MockERC721Base} from "../../contracts/test/MockERC721Base.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Behavioral model of the V4 position manager callback boundary. It
/// enforces NFT custody, the encoded action and payout recipient before calling
/// the hook; it does not claim to replace a full Uniswap V4 deployment.
contract HookedV4PositionManager is MockERC721Base {
    address public immutable currency0;
    address public immutable currency1;
    address public hook;
    uint128 public owed0;
    uint128 public owed1;
    uint256 public constant TOKEN_ID = 1;

    constructor(address a, address b) {
        currency0 = a;
        currency1 = b;
    }

    function setHook(address h) external { hook = h; }
    function mint(address to) external { _mint(to, TOKEN_ID); }
    function setOwed(uint128 a, uint128 b) external { owed0 = a; owed1 = b; }

    function getPoolAndPositionInfo(uint256 id) external view returns (PoolKeyV4 memory key, uint256 info) {
        require(id == TOKEN_ID);
        key = PoolKeyV4(currency0, currency1, 3000, 60, hook);
        info = 0;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external {
        require(deadline >= block.timestamp);
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(actions.length == 2 && uint8(actions[0]) == ActionsV4.DECREASE_LIQUIDITY
            && uint8(actions[1]) == ActionsV4.TAKE_PAIR, "wrong action");
        require(params.length == 2, "wrong params");
        (uint256 id, uint256 liquidity, uint128 min0, uint128 min1, bytes memory hookData) =
            abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
        (address a, address b, address recipient) = abi.decode(params[1], (address, address, address));
        require(ownerOf(id) == msg.sender && liquidity == 0 && min0 == 0 && min1 == 0, "position not held");
        require(a == currency0 && b == currency1, "wrong currencies");
        require(hookData.length == 0, "unexpected hook data");
        if (hook != address(0)) HostileHook(hook).onCollect(msg.sender);
        uint128 pay0 = owed0;
        uint128 pay1 = owed1;
        owed0 = 0;
        owed1 = 0;
        if (pay0 != 0) require(IERC20(currency0).transfer(recipient, pay0));
        if (pay1 != 0) require(IERC20(currency1).transfer(recipient, pay1));
    }
}

contract HostileHook {
    bool public blockClaims;
    bool public ownerMode;
    bool public callbackReached;
    bool public collectBlocked;
    bool public withdrawBlocked;
    bool public nftRescueBlocked;
    bool public ownershipTheftBlocked;
    bool public tokenRescueBlocked;
    bool public unlockReductionBlocked;
    address public immutable manager;
    address public immutable token;

    constructor(address manager_, address token_) { manager = manager_; token = token_; }
    function setBlockClaims(bool value) external { blockClaims = value; }
    function setOwnerMode(bool value) external { ownerMode = value; }
    function claim(address locker) external { TitanLockerV2(payable(locker)).collectFees(); }

    function onCollect(address locker) external {
        if (blockClaims) revert("hook veto");
        callbackReached = true;
        (bool ok,) = locker.call(abi.encodeWithSignature("collectFees()"));
        collectBlocked = !ok;
        (ok,) = locker.call(abi.encodeWithSignature("withdraw()"));
        withdrawBlocked = !ok;
        (ok,) = locker.call(abi.encodeWithSignature("withdrawNft(address,uint256)", manager, 1));
        nftRescueBlocked = !ok;
        (ok,) = locker.call(abi.encodeWithSignature("withdrawToken(address)", token));
        tokenRescueBlocked = !ok;
        if (ownerMode) {
            (ok,) = locker.call(abi.encodeWithSignature("extendLock(uint40)", uint40(199)));
            unlockReductionBlocked = !ok;
        } else {
            (ok,) = locker.call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
            ownershipTheftBlocked = !ok;
        }
    }
}

contract MaliciousV4HookTest is Test {
    TitanLockerManagerV2 manager;
    HookedV4PositionManager pm;
    HostileHook hook;
    TestERC20 token0;
    TestERC20 token1;
    TitanLockerV2 locker;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setUp() public {
        vm.warp(100);
        token0 = new TestERC20("Fee 0", "F0", 100);
        token1 = new TestERC20("Fee 1", "F1", 100);
        manager = new TitanLockerManagerV2(payable(address(0xFEE)));
        manager.setEthFee(0);
        pm = new HookedV4PositionManager(address(token0), address(token1));
        hook = new HostileHook(address(pm), address(token0));
        pm.setHook(address(hook));
        pm.mint(address(this));
        pm.approve(address(manager), 1);
        manager.setPositionManager(address(pm), ITitanLockerManagerV2.LockKind.UNIV4, true);
        manager.createPositionLock(address(pm), 1, 200);
        locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        token0.transfer(address(pm), 10 ether);
        token1.transfer(address(pm), 10 ether);
        pm.setOwed(4 ether, 7 ether);
    }

    function testNonOwnerHookCannotReenterStealOrMovePosition() public {
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        (uint256 paid0, uint256 paid1) = locker.collectFees();
        assertEq(paid0, 4 ether);
        assertEq(paid1, 7 ether);
        assertEq(token0.balanceOf(address(this)) - before0, 4 ether);
        assertEq(token1.balanceOf(address(this)) - before1, 7 ether);
        assertTrue(hook.callbackReached());
        assertTrue(hook.collectBlocked());
        assertTrue(hook.withdrawBlocked());
        assertTrue(hook.nftRescueBlocked());
        assertTrue(hook.ownershipTheftBlocked());
        assertTrue(hook.tokenRescueBlocked());
        assertEq(pm.ownerOf(1), address(locker));
        assertEq(locker.owner(), address(this));
    }

    function testOwnerHookReentrancyBlockedWhileFeePayoutSucceeds() public {
        locker.transferOwnership(address(hook));
        hook.setOwnerMode(true);
        hook.claim(address(locker));
        assertTrue(hook.collectBlocked());
        assertTrue(hook.withdrawBlocked());
        assertTrue(hook.nftRescueBlocked());
        assertTrue(hook.tokenRescueBlocked());
        assertTrue(hook.unlockReductionBlocked());
        assertEq(token0.balanceOf(address(hook)), 4 ether);
        assertEq(token1.balanceOf(address(hook)), 7 ether);
        assertEq(pm.ownerOf(1), address(locker));
    }

    function testOwnerChosenRecipientDoesNotGiveHookControlOfFees() public {
        address recipient = address(0xB0B);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        locker.collectFeesTo(recipient);
        vm.expectRevert();
        locker.collectFeesTo(address(0));
        (uint256 paid0, uint256 paid1) = locker.collectFeesTo(recipient);
        assertEq(paid0, 4 ether);
        assertEq(paid1, 7 ether);
        assertEq(token0.balanceOf(recipient), 4 ether);
        assertEq(token1.balanceOf(recipient), 7 ether);
        assertEq(pm.ownerOf(1), address(locker));
        assertTrue(hook.collectBlocked());
        assertTrue(hook.withdrawBlocked());
        assertTrue(hook.nftRescueBlocked());
    }

    function testHookCanVetoFeeClaimButCannotVetoMaturedNftWithdrawal() public {
        hook.setBlockClaims(true);
        vm.expectRevert(bytes("hook veto"));
        locker.collectFees();
        assertEq(pm.owed0(), 4 ether);
        assertEq(pm.ownerOf(1), address(locker));
        vm.warp(200);
        locker.withdraw();
        assertEq(pm.ownerOf(1), address(this));
    }
}
