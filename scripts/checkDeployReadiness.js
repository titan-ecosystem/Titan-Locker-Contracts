// Pre-deploy readiness check for TitanLockerManagerV2.
// Usage: npx hardhat run scripts/checkDeployReadiness.js --network <network>
// Prints network/deployer/balance/Util status without deploying anything.

const hre = require("hardhat");

async function main() {
  const net = await hre.ethers.provider.getNetwork();
  console.log("Network chainId:", net.chainId.toString());

  let signer;
  try {
    [signer] = await hre.ethers.getSigners();
  } catch (e) {
    console.log("Signer: NONE (no deployer account configured) -", e.message);
    return;
  }
  if (!signer) {
    console.log("Signer: NONE (no deployer account configured)");
    return;
  }

  const addr = await signer.getAddress();
  const bal = await hre.ethers.provider.getBalance(addr);
  console.log("Deployer:", addr);
  console.log("Balance:", hre.ethers.utils.formatEther(bal), "ETH");

  // Util is a linked dependency of the V2 manager deploy
  try {
    const util = await hre.deployments.get("Util");
    console.log("Util (existing deployment):", util.address);
    const code = await hre.ethers.provider.getCode(util.address);
    console.log("Util has code on chain:", code !== "0x");
  } catch (e) {
    console.log("Util deployment record: NOT FOUND -", e.message);
  }

  console.log("READINESS:", bal.gt(0) ? "deployer is funded" : "deployer has ZERO balance - cannot deploy");
}

main().catch((e) => {
  console.error("readiness check failed:", e.message);
  process.exit(1);
});
