// Local-only V2.2 deployment verification. Requires an Anvil fork at
// 127.0.0.1:8545 and the completed local deploy/configuration steps.
const hre = require("hardhat");

const managers = [
  ["Uniswap V3", "0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3", 1],
  ["Uniswap V4", "0x58daec3116aae6d93017baaea7749052e8a04fa7", 2],
  ["SushiSwap V3", "0x51d0e5188afe12d502e29D982d20C190e7816107", 1],
  ["PancakeSwap V3", "0x46A15B0b27311cedF172AB29E4f4766fbE7F4364", 1],
  ["SushiSwap V4 CL", "0xd3d35fBc4E44523CA3cD383C1948322Ddb42F644", 4],
  ["PancakeSwap Infinity CL", "0xeaEA9253A0b75B936a965DbD35B2a3F01831DE74", 4],
];

async function main() {
  if (hre.network.name !== "robinhood-fork") throw new Error("local robinhood-fork network required");
  const { ethers, deployments } = hre;
  if ((await ethers.provider.getNetwork()).chainId !== 4663) throw new Error("fork must report chain 4663");
  const [signer] = await ethers.getSigners();
  const release = await deployments.get("TitanLockerManagerV2_2");
  const util = await deployments.get("Util");
  const artifact = await hre.artifacts.readArtifact("TitanLockerManagerV2");

  // Hardhat's deployment record retains the Util placeholders. Fill their
  // documented offsets before comparing to the actual fork deployment.
  let expected = release.deployedBytecode;
  for (const ref of artifact.deployedLinkReferences["contracts/Util.sol"].Util) {
    const offset = 2 + ref.start * 2;
    expected = expected.slice(0, offset) + util.address.slice(2).toLowerCase()
      + expected.slice(offset + ref.length * 2);
  }
  const deployed = await ethers.provider.getCode(release.address);
  if (deployed.toLowerCase() !== expected.toLowerCase()) throw new Error("manager bytecode mismatch");

  const manager = await ethers.getContractAt("TitanLockerManagerV2", release.address, signer);
  if (!(await manager.ethFee()).eq(ethers.utils.parseEther("0.025"))) throw new Error("wrong flat fee");
  if (String(await manager.tokenFeeBps()) !== "300") throw new Error("wrong token fee");
  const expectedOwner = "0x5C773302FBEED11fA59a6939f0354678738B02DB";
  for (const actual of [await manager.owner(), await manager.feeReceiver()]) {
    if (actual.toLowerCase() !== expectedOwner.toLowerCase()) throw new Error("wrong owner or fee receiver");
  }
  for (const [label, address, kind] of managers) {
    const [actualKind, allowed] = await manager.positionManagerKind(address);
    if (!allowed || String(actualKind) !== String(kind)) throw new Error(`${label}: allowlist mismatch`);
  }

  const tokenFactory = await ethers.getContractFactory("TestERC20", signer);
  const token = await tokenFactory.deploy("Fork rehearsal", "FORK", 1000);
  await token.deployed();
  await (await token.approve(manager.address, ethers.utils.parseEther("10"))).wait();
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  await (await manager.createTokenLock(
    token.address, ethers.utils.parseEther("10"), now + 100, 0,
    { value: ethers.utils.parseEther("0.025") },
  )).wait();
  const lockerAddress = await manager.getTokenLockAddress(0);
  const locker = await ethers.getContractAt("TitanLockerV2", lockerAddress, signer);
  if (!(await token.balanceOf(lockerAddress)).eq(ethers.utils.parseEther("10"))) throw new Error("custody failed");
  let earlyRejected = false;
  try { await locker.callStatic.withdraw(); } catch (_) { earlyRejected = true; }
  if (!earlyRejected) throw new Error("early exit was not rejected");
  await ethers.provider.send("evm_setNextBlockTimestamp", [now + 101]);
  await ethers.provider.send("evm_mine", []);
  await (await locker.withdrawTo(await signer.getAddress())).wait();
  if (!(await token.balanceOf(lockerAddress)).isZero()) throw new Error("matured exit failed");
  console.log("Local Robinhood V2.2 rehearsal passed: bytecode, fees, six managers, custody, and maturity exit.");
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
