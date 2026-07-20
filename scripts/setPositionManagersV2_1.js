// Allowlists Uniswap V3/V4 position managers on TitanLockerManagerV2_1 for
// the connected chain. Same addresses already verified and live on the
// original TitanLockerManagerV2 - see scripts/setPositionManagers.js for the
// verification notes.
//
// Usage: npx hardhat run scripts/setPositionManagersV2_1.js --network <network>
// Signs with the deployer account (must be the manager's current owner).
// Kind: 1 = UNIV3, 2 = UNIV4 (matches the LockKind enum).

const hre = require("hardhat");

const KIND = { UNIV3: 1, UNIV4: 2 };

const POSITION_MANAGERS = {
  // Robinhood Chain — Uniswap v2/v3/v4 are live here.
  4663: [
    { address: "0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3", kind: KIND.UNIV3, label: "Uniswap V3 NonfungiblePositionManager" },
    { address: "0x58daec3116aae6d93017baaea7749052e8a04fa7", kind: KIND.UNIV4, label: "Uniswap V4 PositionManager" },
  ],
};

async function main() {
  const manager = await hre.ethers.getContract("TitanLockerManagerV2_1");
  const { chainId } = await hre.ethers.provider.getNetwork();
  const signerAddress = await manager.signer.getAddress();
  const owner = await manager.owner();

  console.log("Contract:", manager.address);
  console.log("Chain id:", chainId);
  console.log("Signer:  ", signerAddress);
  console.log("Owner:   ", owner);

  if (signerAddress.toLowerCase() !== owner.toLowerCase()) {
    throw new Error("Signer is not the contract owner - aborting before sending any tx.");
  }

  const entries = POSITION_MANAGERS[chainId] || [];
  if (entries.length === 0) {
    console.log("\nNo position managers configured for this chain - nothing to do.");
    return;
  }

  for (const { address, kind, label } of entries) {
    if (address === hre.ethers.constants.AddressZero) {
      throw new Error(`Refusing to allowlist the zero address for "${label}".`);
    }
    const code = await hre.ethers.provider.getCode(address);
    if (code === "0x") {
      throw new Error(`No contract code at ${address} ("${label}") on chain ${chainId} - aborting.`);
    }

    console.log(`\nAllowlisting ${label} (${address}) as kind ${kind}...`);
    await (await manager.setPositionManager(address, kind, true)).wait();

    const [storedKind, allowed] = await manager.positionManagerKind(address);
    console.log(`  -> kind=${storedKind} allowed=${allowed}`);
  }

  console.log("\nDone.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
