// Robinhood V2.2 release fee configuration. Sends owner transactions.
const hre = require("hardhat");

async function main() {
  const network = await hre.ethers.provider.getNetwork();
  if (network.chainId !== 4663) throw new Error("Robinhood Chain 4663 required");
  const deployment = await hre.deployments.get("TitanLockerManagerV2_2");
  const signer = (await hre.ethers.getSigners())[0];
  const manager = await hre.ethers.getContractAt("TitanLockerManagerV2", deployment.address, signer);
  const expectedOwner = "0x5C773302FBEED11fA59a6939f0354678738B02DB";
  if ((await manager.owner()).toLowerCase() !== expectedOwner.toLowerCase()
      || (await signer.getAddress()).toLowerCase() !== expectedOwner.toLowerCase()
      || (await manager.feeReceiver()).toLowerCase() !== expectedOwner.toLowerCase()) {
    throw new Error("owner, signer, or fee receiver differs from approved Robinhood settings");
  }

  const flat = hre.ethers.utils.parseEther("0.025");
  if (process.env.TITAN_V22_CONFIGURE !== "YES") {
    console.log("Read-only owner and fee check passed. Set TITAN_V22_CONFIGURE=YES after release approval.");
    return;
  }
  if (!(await manager.ethFee()).eq(flat)) await (await manager.setEthFee(flat)).wait();
  if (String(await manager.tokenFeeBps()) !== "300") await (await manager.setTokenFeeBps(300)).wait();
  if (!(await manager.ethFee()).eq(flat) || String(await manager.tokenFeeBps()) !== "300") {
    throw new Error("fee configuration verification failed");
  }
  console.log("Robinhood V2.2 fees verified: 0.025 ETH flat, 3% token");
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
