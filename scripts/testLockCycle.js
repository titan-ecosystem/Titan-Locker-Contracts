// End-to-end smoke test against the live TitanLockerManagerV1 deployment:
//   1. Deploy a fresh TestERC20
//   2. Temporarily set ethFee to 0.00001 ETH
//   3. Create a lock (paying the ETH fee) for a ~5 minute unlock window
//   4. Confirm withdrawing before unlockTime reverts (simulated, no gas spent)
//   5. Wait until unlockTime has passed
//   6. Confirm withdrawing after unlockTime succeeds
//   7. Restore ethFee to 0.05 ETH
//
// Usage: npx hardhat run scripts/testLockCycle.js --network robinhood
// Needs DEPLOYER_PRIVATE_KEY (or mnemonic.txt) set to the contract owner's
// key, and enough native gas to cover ~6 transactions plus the 0.00001 ETH fee.

const hre = require("hardhat");

const LOCK_SECONDS = 5 * 60;
const TEST_ETH_FEE = hre.ethers.utils.parseEther("0.00001");
const RESTORE_ETH_FEE = hre.ethers.utils.parseEther("0.05");
const LOCK_AMOUNT = 1000;

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

  console.log("=== 1. Deploying test ERC20 ===");
  const TestERC20 = await hre.ethers.getContractFactory("TestERC20");
  const token = await TestERC20.deploy("Lock Cycle Test Token", "LCT", 1_000_000);
  await token.deployed();
  console.log("Token deployed at:", token.address);

  console.log("\n=== 2. Setting ethFee to 0.00001 ETH ===");
  await (await manager.setEthFee(TEST_ETH_FEE)).wait();
  console.log("ethFee is now:", hre.ethers.utils.formatEther(await manager.ethFee()), "ETH");

  console.log("\n=== 3. Approving and creating a lock ===");
  await (await token.approve(manager.address, LOCK_AMOUNT)).wait();

  const latestBlock = await hre.ethers.provider.getBlock("latest");
  const unlockTime = latestBlock.timestamp + LOCK_SECONDS;

  const createTx = await manager.createTokenLocker(token.address, LOCK_AMOUNT, unlockTime, {
    value: TEST_ETH_FEE,
  });
  await createTx.wait();

  const lockId = Number(await manager.tokenLockerCount()) - 1;
  const lockerAddress = await manager.getTokenLockAddress(lockId);
  const locker = await hre.ethers.getContractAt("TitanLockerV1", lockerAddress);

  console.log("Lock created - id:", lockId, "address:", lockerAddress);
  console.log("Unlocks at:", new Date(unlockTime * 1000).toISOString(), `(in ${LOCK_SECONDS}s)`);

  console.log("\n=== 4. Attempting early withdrawal (should revert) ===");
  try {
    await locker.callStatic.withdraw();
    console.log("UNEXPECTED: early withdrawal did not revert!");
  } catch (e) {
    console.log("PASS: early withdrawal reverted as expected -", e.reason || e.message.split("\n")[0]);
  }

  console.log(`\n=== 5. Waiting for unlock time (${LOCK_SECONDS}s + 30s buffer) ===`);
  await sleep((LOCK_SECONDS + 30) * 1000);

  console.log("\n=== 6. Attempting withdrawal after unlock time (should succeed) ===");
  const balanceBefore = await token.balanceOf(deployer.address);
  await (await locker.withdraw()).wait();
  const balanceAfter = await token.balanceOf(deployer.address);
  console.log(
    "PASS: withdrawal succeeded - balance increased by",
    balanceAfter.sub(balanceBefore).toString(),
    "(expected", LOCK_AMOUNT, ")"
  );

  console.log("\n=== 7. Restoring ethFee to 0.05 ETH ===");
  await (await manager.setEthFee(RESTORE_ETH_FEE)).wait();
  console.log("ethFee is now:", hre.ethers.utils.formatEther(await manager.ethFee()), "ETH");

  console.log("\n=== DONE ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
