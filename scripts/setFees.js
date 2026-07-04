// Updates TitanLockerManagerV1's fee configuration.
// Usage: npx hardhat run scripts/setFees.js --network <network>
// Signs with whatever account hardhat.config.js's deployerAccounts() resolves
// to (DEPLOYER_PRIVATE_KEY if set in .env, otherwise mnemonic.txt) - must be
// the contract's current owner.

const hre = require("hardhat");

const NEW_ETH_FEE = hre.ethers.utils.parseEther("0.05");
const NEW_TOKEN_FEE_BPS = 300; // 3.00%

async function main() {
  const manager = await hre.ethers.getContract("TitanLockerManagerV1");

  const [currentEthFee, currentBps, owner, signerAddress] = await Promise.all([
    manager.ethFee(),
    manager.tokenFeeBps(),
    manager.owner(),
    manager.signer.getAddress(),
  ]);

  console.log("Contract:", manager.address);
  console.log("Signer:  ", signerAddress);
  console.log("Owner:   ", owner);
  console.log("Current ethFee:", hre.ethers.utils.formatEther(currentEthFee), "ETH");
  console.log("Current tokenFeeBps:", currentBps.toString());

  if (signerAddress.toLowerCase() !== owner.toLowerCase()) {
    throw new Error("Signer is not the contract owner - aborting before sending any tx.");
  }

  console.log("\nSetting ethFee to 0.05 ETH...");
  await (await manager.setEthFee(NEW_ETH_FEE)).wait();

  console.log("Setting tokenFeeBps to 300 (3.00%)...");
  await (await manager.setTokenFeeBps(NEW_TOKEN_FEE_BPS)).wait();

  const [newEthFee, newBps] = await Promise.all([manager.ethFee(), manager.tokenFeeBps()]);
  console.log("\nDone. New ethFee:", hre.ethers.utils.formatEther(newEthFee), "ETH");
  console.log("New tokenFeeBps:", newBps.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
