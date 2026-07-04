// End-to-end smoke test of the TOKEN-FEE path (paid in-kind, no ETH sent) -
// the ETH-fee path was already tested separately; withdraw timing logic is
// identical either way (it lives in TitanLockerV1, not the fee branch in
// TitanLockerManagerV1), so this focuses on what's actually different here:
// the fee deduction math and the fee receiver payment.
//
//   1. Deploy a fresh TestERC20
//   2. Create a lock with msg.value = 0 (triggers the token-fee path)
//   3. Confirm the locked amount = deposit - (deposit * tokenFeeBps / 10000)
//   4. Confirm the fee receiver actually received the fee amount
//   5. Wait for a short unlock window, then withdraw and confirm the exact
//      reduced amount comes back
//
// Usage: npx hardhat run scripts/testTokenFeeCycle.js --network robinhood
// Needs DEPLOYER_PRIVATE_KEY (or mnemonic.txt) set to the contract owner's
// key. Does not change any fee configuration - uses whatever tokenFeeBps is
// currently live.

const hre = require("hardhat");

const LOCK_SECONDS = 60;
const DEPOSIT_AMOUNT = 1000;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const manager = await hre.ethers.getContract("TitanLockerManagerV1");
  const [deployer] = await hre.ethers.getSigners();

  const owner = await manager.owner();
  if (deployer.address.toLowerCase() !== owner.toLowerCase()) {
    throw new Error(`Signer ${deployer.address} is not the contract owner (${owner}) - aborting.`);
  }

  const tokenFeeBps = await manager.tokenFeeBps();
  const feeReceiver = await manager.feeReceiver();
  const expectedFee = Math.floor((DEPOSIT_AMOUNT * Number(tokenFeeBps)) / 10000);
  const expectedLocked = DEPOSIT_AMOUNT - expectedFee;

  console.log("Current tokenFeeBps:", tokenFeeBps.toString(), `(${Number(tokenFeeBps) / 100}%)`);
  console.log("Fee receiver:", feeReceiver);
  console.log(`Depositing ${DEPOSIT_AMOUNT} - expecting fee=${expectedFee}, locked=${expectedLocked}`);

  console.log("\n=== 1. Deploying test ERC20 ===");
  const TestERC20 = await hre.ethers.getContractFactory("TestERC20");
  const token = await TestERC20.deploy("Token Fee Test Token", "TFT", 1_000_000);
  await token.deployed();
  console.log("Token deployed at:", token.address);

  console.log("\n=== 2. Approving and creating a lock (token-fee path, no ETH sent) ===");
  await (await token.approve(manager.address, DEPOSIT_AMOUNT)).wait();

  const latestBlock = await hre.ethers.provider.getBlock("latest");
  const unlockTime = latestBlock.timestamp + LOCK_SECONDS;

  // no { value: ... } - msg.value stays 0, so _collectFee takes the token-fee branch
  const createTx = await manager.createTokenLocker(token.address, DEPOSIT_AMOUNT, unlockTime);
  const createReceipt = await createTx.wait();

  const lockId = Number(await manager.tokenLockerCount()) - 1;
  const lockerAddress = await manager.getTokenLockAddress(lockId);
  const locker = await hre.ethers.getContractAt("TitanLockerV1", lockerAddress);
  console.log("Lock created - id:", lockId, "address:", lockerAddress);

  console.log("\n=== 3. Verifying fee math ===");
  // Reading the FeeCollected event directly, rather than diffing the fee
  // receiver's token balance, since fee receiver == deployer == depositor in
  // this deployment - a balance diff there would also capture the unrelated
  // deposit-to-locker transfer on the same address and give a meaningless number.
  const feeCollectedLog = createReceipt.events.find((e) => e.event === "FeeCollected");
  if (!feeCollectedLog) {
    throw new Error("FAIL: no FeeCollected event was emitted");
  }
  const { paidInEth, amount: actualFeePaid } = feeCollectedLog.args;

  const lockData = await locker.getLockData();

  console.log("Locked balance:", lockData.balance.toString(), "(expected", expectedLocked, ")");
  console.log("FeeCollected event - paidInEth:", paidInEth, "amount:", actualFeePaid.toString(), "(expected false,", expectedFee, ")");

  if (lockData.balance.toString() !== String(expectedLocked)) {
    throw new Error("FAIL: locked amount does not match expected fee deduction");
  }
  if (paidInEth !== false) {
    throw new Error("FAIL: FeeCollected reported paidInEth=true, expected the token-fee path");
  }
  if (actualFeePaid.toString() !== String(expectedFee)) {
    throw new Error("FAIL: FeeCollected amount does not match expected fee");
  }
  console.log("PASS: fee math correct and FeeCollected event confirms the in-kind fee was taken");

  console.log(`\n=== 4. Waiting for unlock time (${LOCK_SECONDS}s + 15s buffer) ===`);
  await sleep((LOCK_SECONDS + 15) * 1000);

  console.log("\n=== 5. Withdrawing (should return exactly the reduced amount) ===");
  const ownerBalanceBefore = await token.balanceOf(deployer.address);
  await (await locker.withdraw()).wait();
  const ownerBalanceAfter = await token.balanceOf(deployer.address);
  const received = ownerBalanceAfter.sub(ownerBalanceBefore);

  console.log("Received on withdrawal:", received.toString(), "(expected", expectedLocked, ")");
  if (received.toString() !== String(expectedLocked)) {
    throw new Error("FAIL: withdrawal amount does not match expected");
  }
  console.log("PASS: withdrawal returned exactly the fee-adjusted locked amount");

  console.log("\n=== DONE ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
