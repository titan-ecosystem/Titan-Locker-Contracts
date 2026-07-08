// Allowlists Uniswap V3/V4 position managers on TitanLockerManagerV2 for the
// connected chain. Until a position manager is allowlisted here, no user can
// lock a position against it - this is the per-chain enablement + kill-switch.
//
// Usage: npx hardhat run scripts/setPositionManagers.js --network <network>
// Signs with the deployer account (must be the manager's current owner).
//
// IMPORTANT: VERIFY every address below against the official Uniswap
// deployment docs for that chain before running on mainnet. The script refuses
// to allowlist any address that has no contract code on the connected chain,
// but it cannot tell a correct position manager from a wrong-but-deployed one.
// Kind: 1 = UNIV3, 2 = UNIV4 (matches the LockKind enum).

const hre = require("hardhat");

const KIND = { UNIV3: 1, UNIV4: 2 };

// chainId => [{ address, kind, label }]. Fill in / verify per chain you deploy
// to. Left intentionally sparse: add an entry only once you have confirmed the
// address from Uniswap's own docs and (ideally) fork-tested the V4 path.
const POSITION_MANAGERS = {
  // Ethereum mainnet
  1: [
    { address: "0xC36442b4a4522E871399CD717aBDD847Ab11FE88", kind: KIND.UNIV3, label: "Uniswap V3 NFPM" },
    // { address: "0x<verify>", kind: KIND.UNIV4, label: "Uniswap V4 PositionManager" },
  ],
  // Add arbitrum (42161), base (8453), optimism (10), polygon (137), bsc (56),
  // etc. here after verifying each address. Robinhood Chain (4663) has no
  // Uniswap deployment, so it stays empty.
};

async function main() {
  const manager = await hre.ethers.getContract("TitanLockerManagerV2");
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
