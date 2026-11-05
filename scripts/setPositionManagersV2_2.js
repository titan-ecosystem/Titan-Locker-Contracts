// Configures only the new V2.2 manager. Run after its deployment and fee setup.
// This sends owner transactions; it is not part of the read-only preflight.
const hre = require("hardhat");

const ROBINHOOD_MANAGERS = [
  { address: "0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3", kind: 1, label: "Uniswap V3" },
  { address: "0x58daec3116aae6d93017baaea7749052e8a04fa7", kind: 2, label: "Uniswap V4" },
  {
    address: "0x51d0e5188afe12d502e29D982d20C190e7816107", kind: 1, label: "SushiSwap V3",
    codeHash: "0x93231e1dfce78dc40086b4e5b2aa6bd5e10e34fe87d171002f2f6653cf054485",
    factory: "0xE51960f1B45f1C9FB6D166E6a884F866fC70433B",
  },
  {
    address: "0x46A15B0b27311cedF172AB29E4f4766fbE7F4364", kind: 1, label: "PancakeSwap V3",
    codeHash: "0x1f78ea9b8894f894de8ed49ad312e37c1c15a4fbe5783bd41fb4a2e586d45f7f",
    factory: "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865",
  },
  {
    address: "0xd3d35fBc4E44523CA3cD383C1948322Ddb42F644", kind: 4, label: "SushiSwap V4 CL",
    codeHash: "0x60b472b4b6438e6b607c32610b4fdd0843a9d51a0dccb7656060264af149de54",
  },
  {
    address: "0xeaEA9253A0b75B936a965DbD35B2a3F01831DE74", kind: 4, label: "PancakeSwap Infinity CL",
    codeHash: "0xfd5134fd952bcf0fc731084ffcfbfc7ece52d7ffd001b1a952de7ee9b6273b4f",
  },
];

async function main() {
  const network = await hre.ethers.provider.getNetwork();
  if (network.chainId !== 4663) throw new Error("Robinhood Chain 4663 required");
  const deployment = await hre.deployments.get("TitanLockerManagerV2_2");
  const signer = (await hre.ethers.getSigners())[0];
  const manager = await hre.ethers.getContractAt("TitanLockerManagerV2", deployment.address, signer);
  if ((await signer.getAddress()).toLowerCase() !== (await manager.owner()).toLowerCase()) {
    throw new Error("signer is not manager owner");
  }

  // Validate every integration before sending the first transaction.
  for (const entry of ROBINHOOD_MANAGERS) {
    const code = await hre.ethers.provider.getCode(entry.address);
    if (code === "0x") throw new Error(`${entry.label}: no contract code`);
    if (entry.codeHash && hre.ethers.utils.keccak256(code).toLowerCase() !== entry.codeHash.toLowerCase()) {
      throw new Error(`${entry.label}: code hash changed; stop and re-audit`);
    }
    if (entry.factory) {
      const pm = new hre.ethers.Contract(entry.address, ["function factory() view returns (address)"], hre.ethers.provider);
      if ((await pm.factory()).toLowerCase() !== entry.factory.toLowerCase()) {
        throw new Error(`${entry.label}: factory changed; stop and re-audit`);
      }
    }
  }

  if (process.env.TITAN_V22_CONFIGURE !== "YES") {
    console.log("Read-only verification passed. Set TITAN_V22_CONFIGURE=YES after release approval.");
    return;
  }

  for (const entry of ROBINHOOD_MANAGERS) {
    const [kind, allowed] = await manager.positionManagerKind(entry.address);
    if (allowed && Number(kind) === entry.kind) continue;
    await (await manager.setPositionManager(entry.address, entry.kind, true)).wait();
    const [liveKind, liveAllowed] = await manager.positionManagerKind(entry.address);
    if (!liveAllowed || Number(liveKind) !== entry.kind) throw new Error(`${entry.label}: verification failed`);
    console.log(`Configured ${entry.label}: ${entry.address}`);
  }
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
