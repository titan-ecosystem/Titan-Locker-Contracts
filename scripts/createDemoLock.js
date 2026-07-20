// Creates one real lock on the live TitanLockerManagerV1 deployment with a
// long (~69 day) unlock time, purely so the frontend has a real "still
// locked, weeks left" card to render alongside the already-withdrawn demo
// locks from earlier testing.
//
// Locks 10% of the demo token's total supply (properly scaled by decimals,
// not a bare raw-unit amount) so it renders as a normal-looking balance
// instead of a fraction of a wei.
//
// Pays the fee via the token-fee path (no ETH required beyond gas) - doesn't
// touch the live ethFee/tokenFeeBps config, so no owner privileges needed and
// nothing needs restoring afterward. Any funded wallet can run this.
//
// Usage: npx hardhat run scripts/createDemoLock.js --network robinhood
const hre = require("hardhat");

const LOCK_SECONDS = 69 * 24 * 60 * 60; // 69 days
const SUPPLY = 1_000_000; // whole tokens, scaled by decimals in TestERC20's constructor

async function main() {
  const manager = await hre.ethers.getContract("TitanLockerManagerV1");
  const [signer] = await hre.ethers.getSigners();

  console.log("=== 1. Deploying test ERC20 ===");
  const TestERC20 = await hre.ethers.getContractFactory("TestERC20");
  const token = await TestERC20.deploy("Titan Demo Token", "TDT", SUPPLY);
  await token.deployed();
  console.log("Token deployed at:", token.address);

  const totalSupply = await token.totalSupply();
  const lockAmount = totalSupply.div(10); // 10% of supply
  console.log("Total supply:", hre.ethers.utils.formatUnits(totalSupply), "TDT");
  console.log("Locking 10%:", hre.ethers.utils.formatUnits(lockAmount), "TDT");

  console.log("\n=== 2. Approving and creating a 69-day lock ===");
  await (await token.approve(manager.address, lockAmount)).wait();

  const latestBlock = await hre.ethers.provider.getBlock("latest");
  const unlockTime = latestBlock.timestamp + LOCK_SECONDS;

  const createTx = await manager.createTokenLocker(token.address, lockAmount, unlockTime);
  await createTx.wait();

  const lockId = Number(await manager.tokenLockerCount()) - 1;
  const lockerAddress = await manager.getTokenLockAddress(lockId);

  console.log("Lock created - id:", lockId, "address:", lockerAddress);
  console.log("Signer:", signer.address);
  console.log("Unlocks at:", new Date(unlockTime * 1000).toISOString(), `(in ${LOCK_SECONDS / 86400} days)`);
  console.log(`\nView it at: /lock/${lockId}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
