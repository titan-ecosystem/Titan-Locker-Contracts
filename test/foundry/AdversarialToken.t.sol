// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TitanLockerManagerV2} from "../../contracts/TitanLockerManagerV2.sol";
import {TitanLockerV2} from "../../contracts/TitanLockerV2.sol";

contract ReenteringERC20 is ERC20 {
    TitanLockerManagerV2 public manager;
    bool public attempted;
    bool public blockedByGuard;

    constructor() ERC20("Callback", "CALL") { _mint(msg.sender, 1000 ether); }
    function setManager(TitanLockerManagerV2 m) external { manager = m; }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (msg.sender == address(manager) && !attempted) {
            attempted = true;
            (bool ok, bytes memory reason) = address(manager).call(
                abi.encodeWithSelector(manager.createTokenLock.selector, address(this), 1 ether, uint40(200), uint16(300))
            );
            bytes4 selector;
            if (reason.length >= 4) assembly { selector := mload(add(reason, 32)) }
            blockedByGuard = !ok && selector == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        }
        return super.transferFrom(from, to, value);
    }
}

contract TransferTaxERC20 is ERC20 {
    constructor() ERC20("Tax", "TAX") { _mint(msg.sender, 1000 ether); }
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            uint256 tax = value / 10;
            super._update(from, to, value - tax);
            if (tax != 0) super._update(from, address(0), tax);
        } else {
            super._update(from, to, value);
        }
    }
}

contract AdversarialTokenTest is Test {
    TitanLockerManagerV2 manager;
    address payable feeReceiver = payable(address(0xFEE));

    function setUp() public {
        vm.warp(100);
        vm.deal(address(this), 1 ether);
        manager = new TitanLockerManagerV2(feeReceiver);
        manager.setEthFee(0.025 ether);
        manager.setTokenFeeBps(300);
    }

    function testCallbackTokenCannotReenterManagerDuringFeeTransfer() public {
        ReenteringERC20 token = new ReenteringERC20();
        token.setManager(manager);
        token.approve(address(manager), type(uint256).max);
        manager.createTokenLock(address(token), 100 ether, 200, 300);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        assertTrue(token.attempted());
        assertTrue(token.blockedByGuard());
        assertEq(manager.tokenLockerCount(), 1);
        assertEq(token.balanceOf(address(locker)), 97 ether);
        assertEq(token.balanceOf(feeReceiver), 3 ether);
    }

    function testTransferTaxAccountingAndVestingClampsToActualBalance() public {
        TransferTaxERC20 token = new TransferTaxERC20();
        token.approve(address(manager), type(uint256).max);
        manager.createVestingLock{value: 0.025 ether}(address(token), 100 ether, 110, 110, 200, 0);
        TitanLockerV2 locker = TitanLockerV2(payable(manager.getTokenLockAddress(0)));
        (,,, uint256 nominalGrant,) = locker.getVesting();
        assertEq(nominalGrant, 100 ether);
        assertEq(token.balanceOf(address(locker)), 90 ether);
        vm.warp(200);
        assertEq(locker.releasable(), 90 ether);
        assertEq(locker.release(), 90 ether);
        assertEq(token.balanceOf(address(locker)), 0);
        assertEq(locker.releasedAmount(), 90 ether);
        assertEq(locker.releasable(), 0);
    }
}
