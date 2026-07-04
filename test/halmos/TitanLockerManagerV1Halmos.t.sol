// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TitanLockerManagerV1 } from "../../contracts/TitanLockerManagerV1.sol";
import { TestERC20 } from "../../contracts/test/TestERC20.sol";
import { Ownable } from "../../contracts/Ownable.sol";

/// @notice Halmos symbolic tests for TitanLockerManagerV1's fee math and
/// access control (mirrors test/foundry/TitanLockerManagerV1.t.sol's setup).
///
/// Unlike the Foundry fuzz suite, which samples a bounded number of random
/// (amount, bps, caller, ...) tuples per run, every `check_*` function below
/// is proven (or disproven with a concrete counterexample) for the ENTIRE
/// symbolic domain declared by its parameters and `vm.assume` bounds.
contract TitanLockerManagerV1HalmosTest is Test {
  uint16 internal constant BPS_DENOMINATOR = 10000;

  TitanLockerManagerV1 internal manager;
  TestERC20 internal token;
  address internal feeReceiver;
  address internal owner = address(this);

  function setUp() public {
    // A plain concrete constant rather than `makeAddr("feeReceiver")`: Halmos
    // models `makeAddr`'s result as an uninterpreted symbol, and comparing
    // `token.balanceOf()` reads keyed by that symbol across multiple storage
    // accesses produced spurious counterexamples (verified against a
    // concrete `forge test` replay of the exact reported inputs, which
    // passes) - a known class of symbolic-storage-hashing false positive,
    // not a real property violation. A concrete address sidesteps it
    // entirely without weakening what's being proven.
    feeReceiver = address(0xFEE);
    manager = new TitanLockerManagerV1(payable(feeReceiver));
    token = new TestERC20("Halmos Token", "HLM", 1_000_000_000);
  }

  function _latestLockerAddress() internal view returns (address) {
    uint40 id = manager.tokenLockerCount() - 1;
    return manager.getTokenLockAddress(id);
  }

  /// @dev Core fee-math property, proven rather than sampled: on the
  /// token-percentage path (msg.value == 0), for ANY symbolic `amount` in
  /// [1, token.totalSupply()] and ANY symbolic `bps` in the contract's own
  /// valid domain [0, 10000], the amount that actually reaches the locker can
  /// never exceed the amount the caller asked to lock, and equals the exact
  /// `amount - (amount * bps) / BPS_DENOMINATOR` formula. This is exactly the
  /// kind of arithmetic property (a division/multiplication invariant that
  /// must hold at every point of a 2-D input space) that symbolic execution
  /// is suited to prove exhaustively, where a fuzzer can only spot-check it.
  function check_tokenFeeNeverExceedsAmount(uint256 amount, uint16 bps) public {
    vm.assume(bps <= BPS_DENOMINATOR);
    amount = 1 + (amount % token.totalSupply()); // bound into [1, totalSupply], keeping every reachable value

    manager.setTokenFeeBps(bps);

    token.approve(address(manager), amount);
    manager.createTokenLocker(address(token), amount, uint40(block.timestamp) + 1);

    address lockerAddress = _latestLockerAddress();
    uint256 amountToLock = token.balanceOf(lockerAddress);

    assertLe(amountToLock, amount, "amountToLock must never exceed the requested amount");

    uint256 expectedFee = (amount * bps) / BPS_DENOMINATOR;
    assertEq(amountToLock, amount - expectedFee, "amountToLock must equal amount minus the bps fee");
    assertEq(token.balanceOf(feeReceiver), expectedFee, "feeReceiver must receive exactly the bps fee");
  }

  /// @dev Access-control property: for ANY symbolic caller address that is
  /// not the manager's owner, setEthFee always reverts with CallerNotOwner
  /// and never changes `_ethFee`. Proven over the entire address space
  /// (2^160 possible callers), not just the handful an EVM fuzzer would try.
  function check_onlyOwnerCanSetEthFee(address caller, uint256 newFee) public {
    vm.assume(caller != owner);

    uint256 ethFeeBefore = manager.ethFee();

    // Halmos 0.3.3 does not implement vm.expectRevert (any overload) - see
    // https://github.com/a16z/halmos/wiki/Supported-Foundry-Cheatcodes. Use
    // native try/catch instead and assert on the exact revert data.
    vm.prank(caller);
    try manager.setEthFee(newFee) {
      assertTrue(false, "setEthFee must revert for a non-owner caller");
    } catch (bytes memory reason) {
      assertEq(
        reason,
        abi.encodeWithSelector(Ownable.CallerNotOwner.selector, caller),
        "must revert with CallerNotOwner(caller)"
      );
    }

    assertEq(manager.ethFee(), ethFeeBefore, "a reverted setter must not change state");
  }

  /// @dev Cap-enforcement property (the "above cap" half): for ANY symbolic
  /// `bps` strictly greater than BPS_DENOMINATOR (10000), setTokenFeeBps
  /// always reverts with TokenFeeTooHigh and leaves the stored value
  /// unchanged. Together with check_setTokenFeeBpsAcceptsValidRange below,
  /// this proves the cap sits at exactly the documented boundary with no
  /// off-by-one in either direction - something a fuzzer would need to get
  /// lucky to land on (e.g. bps == 10001 specifically).
  function check_setTokenFeeBpsRevertsAboveCap(uint16 bps) public {
    vm.assume(bps > BPS_DENOMINATOR);
    uint16 before = manager.tokenFeeBps();

    try manager.setTokenFeeBps(bps) {
      assertTrue(false, "setTokenFeeBps must revert above the cap");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(TitanLockerManagerV1.TokenFeeTooHigh.selector), "must revert with TokenFeeTooHigh");
    }

    assertEq(manager.tokenFeeBps(), before, "a reverted setter must not change state");
  }

  /// @dev Cap-enforcement property (the "at or below cap" half): for ANY
  /// symbolic `bps` in [0, 10000], setTokenFeeBps always succeeds and stores
  /// the value verbatim.
  function check_setTokenFeeBpsAcceptsValidRange(uint16 bps) public {
    vm.assume(bps <= BPS_DENOMINATOR);
    manager.setTokenFeeBps(bps);
    assertEq(manager.tokenFeeBps(), bps);
  }

  /// @dev Property: a fee-exempt account always gets 100% of its symbolic
  /// `amount` locked and pays no token fee at all, for ANY symbolic
  /// `tokenFeeBps` currently configured - exemption always wins over the
  /// percentage path, proven jointly over both symbolic dimensions at once.
  function check_feeExemptAccountPaysNoFee(uint256 amount, uint16 bps) public {
    vm.assume(bps <= BPS_DENOMINATOR);
    amount = 1 + (amount % token.totalSupply());

    manager.setTokenFeeBps(bps);
    manager.setFeeExempt(owner, true);

    token.approve(address(manager), amount);
    manager.createTokenLocker(address(token), amount, uint40(block.timestamp) + 1);

    address lockerAddress = _latestLockerAddress();

    assertEq(token.balanceOf(lockerAddress), amount, "exempt caller must lock 100% of amount");
    assertEq(token.balanceOf(feeReceiver), 0, "exempt caller must pay no fee");
  }
}
