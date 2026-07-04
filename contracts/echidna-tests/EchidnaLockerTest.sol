// SPDX-License-Identifier: GPL-3.0-or-later
// Echidna property/assertion tests for TitanLockerManagerV1 + TitanLockerV1.
//
// NOTE: this file (and everything else under contracts/echidna-tests/) is
// fuzz-harness-only code. It is never deployed as part of the product and
// does not modify any existing contract. (Named "echidna-tests" rather than
// the more obvious "echidna" because this Foundry toolchain silently
// excludes any source directory literally named "echidna" from compilation
// - see the README note in echidna.yaml's sibling discussion in the final
// report for details.)
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TitanLockerManagerV1 } from "../TitanLockerManagerV1.sol";
import { TitanLockerV1 } from "../TitanLockerV1.sol";
import { TestERC20 } from "../test/TestERC20.sol";

/// @dev A minimal "actor" contract used to make calls that show up to the
/// target contracts as coming from an address that is genuinely distinct
/// from the harness itself. This is what lets us actually test
/// access-control (onlyOwner) properties: Solidity has no way to spoof
/// msg.sender for an external call, so the only way to have the manager see
/// two different callers is to route calls through two different contract
/// addresses.
contract Actor {
  function relay(address target_, bytes calldata data_) external returns (bool success, bytes memory ret) {
    (success, ret) = target_.call(data_);
  }

  function approveToken(IERC20 token_, address spender_, uint256 amount_) external {
    token_.approve(spender_, amount_);
  }
}

/// @notice Echidna assertion-mode harness. Echidna calls the external
/// functions below (in fuzzed sequences, from its default set of sender
/// EOAs) and every `assert()` inside them (or reached transitively) becomes
/// a fuzzed property. Boolean `echidna_*` view functions are checked as
/// invariants after every call in the sequence.
contract EchidnaLockerTest {
  uint16 private constant BPS_DENOMINATOR = 10000;
  uint40 private constant MAX_LOCK_DURATION = 7 days;

  TitanLockerManagerV1 internal manager;
  TestERC20 internal token;

  // `ownerActor` deploys/owns the manager for the lifetime of the campaign.
  // `attacker1`/`attacker2` are never granted any privilege and are used to
  // fuzz "non-owner calls an owner-only setter" scenarios.
  Actor internal ownerActor;
  Actor internal attacker1;
  Actor internal attacker2;

  address payable internal constant FEE_RECEIVER = payable(address(uint160(0xFEEBEEF)));

  // ids of every lock ever created by this harness
  uint40[] internal lockIds;
  // ghost accounting: sum of everything ever successfully deposited into a
  // given lock id (via createTokenLocker's initial deposit + deposit()),
  // net of the manager's token fee. Used to prove the locker's held balance
  // can never exceed what was genuinely put into it.
  mapping(uint40 => uint256) internal totalDeposited;
  mapping(uint40 => uint40) internal lastKnownUnlockTime;

  constructor() {
    // huge supply so thousands of fuzzed calls (with fee bleed on every
    // token-fee-paid creation) don't exhaust the harness's own balance
    // before the campaign is done.
    token = new TestERC20("Fuzz Token", "FUZZ", 1_000_000_000_000);

    manager = new TitanLockerManagerV1(FEE_RECEIVER);

    ownerActor = new Actor();
    attacker1 = new Actor();
    attacker2 = new Actor();

    // The harness itself deployed `manager` above, so the harness is the
    // initial owner (Ownable(_msgSender()) in the manager's constructor).
    // Hand ownership to a dedicated Actor so "only the owner can call X" is
    // actually meaningful to fuzz: nobody but ownerActor can ever again make
    // a call that manager sees as coming from the owner.
    manager.transferOwnership(address(ownerActor));

    // let the manager pull deposit/fee amounts from the harness's own
    // balance for every createTokenLocker call.
    token.approve(address(manager), type(uint256).max);
  }

  // ---------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------

  function _pickActor(bool useSecond_) private view returns (Actor) {
    return useSecond_ ? attacker2 : attacker1;
  }

  function _boundedAmount(uint256 amount_) private view returns (uint256) {
    uint256 bal = token.balanceOf(address(this));
    if (bal == 0) return 0;
    return 1 + (amount_ % bal);
  }

  // ---------------------------------------------------------------------
  // lock creation / fee-math properties
  // ---------------------------------------------------------------------

  /// Property: the fee math in `_collectFee` can never lock out more than
  /// was deposited, and `tokenFeeBps` can never exceed 100%. Exercises the
  /// real `createTokenLocker` path (both the ETH-fee and token-fee-bps
  /// branches), and independently re-derives the fee off-chain to compare.
  function createLock(uint256 amount_, uint40 lockDurationSeed_, bool payEthFee_) external {
    uint256 amount = _boundedAmount(amount_);
    if (amount == 0) return;

    uint40 unlockTime = uint40(block.timestamp) + 1 + (lockDurationSeed_ % MAX_LOCK_DURATION);

    uint256 ethToSend = 0;
    if (payEthFee_) {
      ethToSend = manager.ethFee();
      if (address(this).balance < ethToSend) return;
    }

    uint16 bpsBefore = manager.tokenFeeBps();
    uint40 idBefore = manager.tokenLockerCount();

    try manager.createTokenLocker{ value: ethToSend }(address(token), amount, unlockTime) {
      uint40 id = idBefore;
      address lockerAddr = manager.getTokenLockAddress(id);

      uint256 expectedLocked;
      if (payEthFee_) {
        expectedLocked = amount;
      } else {
        uint256 fee = (amount * bpsBefore) / BPS_DENOMINATOR;
        expectedLocked = amount - fee;
      }

      // core fee-math invariant: deducting a fee can never *increase* the
      // amount that ends up locked, and the fee itself can never exceed the
      // deposited amount.
      assert(expectedLocked <= amount);

      // the locker must hold exactly what we computed it should hold, and
      // never more than what this harness ever transferred to it.
      assert(token.balanceOf(lockerAddr) == expectedLocked);

      lockIds.push(id);
      totalDeposited[id] = expectedLocked;
      lastKnownUnlockTime[id] = unlockTime;

      // let the harness top up / extend this exact lock later on
      token.approve(lockerAddr, type(uint256).max);
    } catch {
      // reverts are fine (e.g. insufficient allowance/balance, creation
      // disabled, wrong eth fee, etc.) - nothing to assert here.
    }
  }

  /// Standing invariant, re-checked independently of any specific call:
  /// tokenFeeBps must never be settable above 100%.
  function echidna_tokenFeeBps_never_exceeds_max() external view returns (bool) {
    return manager.tokenFeeBps() <= BPS_DENOMINATOR;
  }

  /// Pure re-statement of the fee formula for arbitrary (amount, bps),
  /// bounding bps to the legal range - fee deduction must never inflate the
  /// locked amount, for any amount/bps combination, not just ones that
  /// happen to get proposed through createLock.
  function checkFeeMathIsSound(uint256 amount_, uint16 bpsSeed_) external pure {
    uint16 bps = uint16(bpsSeed_ % (BPS_DENOMINATOR + 1));
    uint256 fee = (amount_ * bps) / BPS_DENOMINATOR;
    uint256 amountToLock = amount_ - fee;
    assert(amountToLock <= amount_);
    assert(fee <= amount_);
  }

  // ---------------------------------------------------------------------
  // deposit() / unlockTime monotonicity + no-phantom-balance properties
  // ---------------------------------------------------------------------

  /// Property: `deposit()`'s extend-lock-time path can only ever push
  /// `unlockTime` forward (or leave it, when newUnlockTime_ == 0), and the
  /// locker's held balance can never exceed the sum of everything this
  /// harness ever deposited into it.
  function depositMore(uint256 lockIndex_, uint256 amount_, uint40 extendSeed_, bool extend_) external {
    if (lockIds.length == 0) return;
    uint40 id = lockIds[lockIndex_ % lockIds.length];
    address lockerAddr = manager.getTokenLockAddress(id);
    TitanLockerV1 locker = TitanLockerV1(payable(lockerAddr));

    uint40 oldUnlock = lastKnownUnlockTime[id];
    uint40 newUnlockTime = extend_ ? oldUnlock + 1 + (extendSeed_ % MAX_LOCK_DURATION) : 0;

    uint256 amount = _boundedAmount(amount_) / 4; // leave room for other fuzzed calls

    try locker.deposit(amount, newUnlockTime) {
      if (amount != 0) totalDeposited[id] += amount;
      if (newUnlockTime != 0) {
        assert(newUnlockTime >= oldUnlock); // never moves backwards
        lastKnownUnlockTime[id] = newUnlockTime;
      }
    } catch {
      // insufficient balance/allowance, or (see tryReduceUnlockTime for the
      // deliberate negative case) an attempted reduction - both fine.
    }

    // re-check on-chain state matches our ghost bookkeeping regardless of
    // whether this specific call succeeded.
    (, , , , , , , uint40 actualUnlock, uint256 actualBalance, ) = locker.getLockData();
    assert(actualUnlock >= oldUnlock);
    assert(actualBalance <= totalDeposited[id]);
  }

  /// Property: explicitly attempting to *reduce* unlockTime via deposit()
  /// must always revert.
  function tryReduceUnlockTime(uint256 lockIndex_, uint40 newUnlockTime_) external {
    if (lockIds.length == 0) return;
    uint40 id = lockIds[lockIndex_ % lockIds.length];
    uint40 oldUnlock = lastKnownUnlockTime[id];
    if (newUnlockTime_ == 0 || newUnlockTime_ >= oldUnlock) return;

    TitanLockerV1 locker = TitanLockerV1(payable(manager.getTokenLockAddress(id)));
    try locker.deposit(0, newUnlockTime_) {
      assert(false); // must never succeed in reducing the unlock time
    } catch {
      // expected
    }
  }

  // ---------------------------------------------------------------------
  // withdraw() timing property
  // ---------------------------------------------------------------------

  /// Property: withdraw() must never succeed before unlockTime, and when it
  /// does succeed, the harness's token balance must not have decreased.
  function withdrawLock(uint256 lockIndex_) external {
    if (lockIds.length == 0) return;
    uint40 id = lockIds[lockIndex_ % lockIds.length];
    TitanLockerV1 locker = TitanLockerV1(payable(manager.getTokenLockAddress(id)));
    uint40 unlockTime = lastKnownUnlockTime[id];
    uint256 balBefore = token.balanceOf(address(this));

    try locker.withdraw() {
      assert(uint40(block.timestamp) >= unlockTime);
      assert(token.balanceOf(address(this)) >= balBefore);
    } catch {
      // reverting is always acceptable; nothing further to assert.
    }
  }

  /// Same property, phrased as a deliberate negative test: only exercised
  /// when we *know* we are still before unlockTime, and asserts the call
  /// must revert.
  function tryEarlyWithdraw(uint256 lockIndex_) external {
    if (lockIds.length == 0) return;
    uint40 id = lockIds[lockIndex_ % lockIds.length];
    if (uint40(block.timestamp) >= lastKnownUnlockTime[id]) return;

    TitanLockerV1 locker = TitanLockerV1(payable(manager.getTokenLockAddress(id)));
    try locker.withdraw() {
      assert(false); // must never succeed before unlockTime
    } catch {
      // expected
    }
  }

  // ---------------------------------------------------------------------
  // access-control properties (owner-only setters)
  // ---------------------------------------------------------------------

  function attackerCannotSetFeeExempt(address account_, bool exempt_, bool useSecond_) external {
    Actor attacker = _pickActor(useSecond_);
    (bool success, ) = attacker.relay(
      address(manager),
      abi.encodeWithSelector(manager.setFeeExempt.selector, account_, exempt_)
    );
    assert(!success);
  }

  function attackerCannotSetCreationEnabled(bool value_, bool useSecond_) external {
    Actor attacker = _pickActor(useSecond_);
    (bool success, ) = attacker.relay(
      address(manager),
      abi.encodeWithSelector(manager.setCreationEnabled.selector, value_)
    );
    assert(!success);
  }

  function attackerCannotSetEthFee(uint256 value_, bool useSecond_) external {
    Actor attacker = _pickActor(useSecond_);
    (bool success, ) = attacker.relay(address(manager), abi.encodeWithSelector(manager.setEthFee.selector, value_));
    assert(!success);
  }

  function attackerCannotSetTokenFeeBps(uint16 value_, bool useSecond_) external {
    Actor attacker = _pickActor(useSecond_);
    (bool success, ) = attacker.relay(
      address(manager),
      abi.encodeWithSelector(manager.setTokenFeeBps.selector, value_)
    );
    assert(!success);
  }

  function attackerCannotSetFeeReceiver(address payable value_, bool useSecond_) external {
    if (value_ == address(0)) return;
    Actor attacker = _pickActor(useSecond_);
    (bool success, ) = attacker.relay(
      address(manager),
      abi.encodeWithSelector(manager.setFeeReceiver.selector, value_)
    );
    assert(!success);
  }

  function attackerCannotTransferOwnership(address newOwner_, bool useSecond_) external {
    Actor attacker = _pickActor(useSecond_);
    (bool success, ) = attacker.relay(
      address(manager),
      abi.encodeWithSelector(manager.transferOwnership.selector, newOwner_)
    );
    assert(!success);
    assert(manager.owner() == address(ownerActor));
  }

  /// Positive control: the real owner (routed through ownerActor) must
  /// still be able to exercise every setter above, and the change must
  /// stick. This guards against the harness itself being wired wrong (e.g.
  /// ownership never actually transferring), which would otherwise make the
  /// negative "attacker" properties above pass vacuously.
  function ownerCanSetFeeExempt(address account_, bool exempt_) external {
    (bool success, ) = ownerActor.relay(
      address(manager),
      abi.encodeWithSelector(manager.setFeeExempt.selector, account_, exempt_)
    );
    assert(success);
    assert(manager.isExemptFromFees(account_) == exempt_);
  }

  function ownerCanSetTokenFeeBpsWithinRange(uint16 bpsSeed_) external {
    uint16 bps = uint16(bpsSeed_ % (BPS_DENOMINATOR + 1));
    (bool success, ) = ownerActor.relay(
      address(manager),
      abi.encodeWithSelector(manager.setTokenFeeBps.selector, bps)
    );
    assert(success);
    assert(manager.tokenFeeBps() == bps);
    assert(manager.tokenFeeBps() <= BPS_DENOMINATOR);
  }

  /// Property: even the legitimate owner can never push tokenFeeBps above
  /// 100% - `setTokenFeeBps` must revert.
  function ownerCannotSetTokenFeeBpsTooHigh(uint16 bpsSeed_) external {
    uint16 bps = uint16(BPS_DENOMINATOR + 1 + (bpsSeed_ % 60000));
    (bool success, ) = ownerActor.relay(
      address(manager),
      abi.encodeWithSelector(manager.setTokenFeeBps.selector, bps)
    );
    assert(!success);
  }

  // ---------------------------------------------------------------------
  // global invariants
  // ---------------------------------------------------------------------

  /// No lock's actual held balance ever exceeds everything ever genuinely
  /// deposited into it (no phantom minting/balance inflation anywhere in
  /// the createTokenLocker/deposit paths).
  function echidna_no_lock_balance_exceeds_deposits() external view returns (bool) {
    uint256 len = lockIds.length;
    for (uint256 i = 0; i < len; i++) {
      uint40 id = lockIds[i];
      address lockerAddr = manager.getTokenLockAddress(id);
      if (token.balanceOf(lockerAddr) > totalDeposited[id]) return false;
    }
    return true;
  }

  /// Ownership of the manager can only ever be the dedicated ownerActor -
  /// nothing in the fuzzed call surface should ever be able to move it.
  function echidna_manager_owner_is_owner_actor() external view returns (bool) {
    return manager.owner() == address(ownerActor);
  }

  /// The three standing invariants above as an explicit assertion, so they
  /// are also exercised (and any violation is reported) when running under
  /// Echidna's `assertion` test mode, which only inspects `assert()` calls
  /// reached from a fuzzed call and does not evaluate `echidna_*` boolean
  /// properties on its own. Property-mode campaigns get both for free; this
  /// keeps assertion-mode campaigns covered too.
  function checkStandingInvariants() external view {
    assert(this.echidna_no_lock_balance_exceeds_deposits());
    assert(this.echidna_manager_owner_is_owner_actor());
    assert(this.echidna_tokenFeeBps_never_exceeds_max());
  }
}
