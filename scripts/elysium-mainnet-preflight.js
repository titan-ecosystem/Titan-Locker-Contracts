#!/usr/bin/env node
// Read-only release check. This file never signs or broadcasts transactions.
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const root = path.resolve(__dirname, "..");
const manifestPath = path.join(root, "deployments/elysium-mainnet.release.json");
const artifactPath = path.join(root, "artifacts/contracts/TitanLockerManagerV2.sol/TitanLockerManagerV2.json");
const childArtifactPath = path.join(root, "artifacts/contracts/TitanLockerV2.sol/TitanLockerV2.json");
const zero = ethers.constants.AddressZero;

function check(condition, message) {
  if (!condition) throw new Error(message);
}

function address(value, name) {
  check(typeof value === "string", `${name} is missing`);
  let parsed;
  try { parsed = ethers.utils.getAddress(value); }
  catch { throw new Error(`${name} is not a valid address`); }
  check(parsed !== zero, `${name} cannot be zero`);
  return parsed;
}

function integer(value, name, max) {
  check(typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= max,
    `${name} must be an integer from 0 to ${max}`);
  return value;
}

async function main() {
  const stage = process.argv[2] || "predeploy";
  check(stage === "predeploy" || stage === "postdeploy", "stage must be predeploy or postdeploy");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  check(manifest.network === "Kinetiq Elysium mainnet", "wrong network label");
  check(manifest.officialNetworkSource === "https://elysium.kinetiq.xyz/docs/connecting-to-elysium",
    "official network source must be Kinetiq's connection guide");

  // Kinetiq's testnet is known. Mainnet is intentionally not guessed here.
  const chainId = integer(manifest.officialChainId, "officialChainId", 2147483647);
  check(![0, 99801, 1338, 1339, 5782].includes(chainId),
    "testnet or unrelated Elysium chain ID cannot be used for Kinetiq mainnet");
  const expectedOwner = address(manifest.owner, "owner");
  const expectedReceiver = address(manifest.feeReceiver, "feeReceiver");
  check(typeof manifest.nativeFeeWei === "string" && /^\d+$/.test(manifest.nativeFeeWei),
    "nativeFeeWei must be a decimal wei string");
  const nativeFeeWei = ethers.BigNumber.from(manifest.nativeFeeWei);
  const tokenFeeBps = integer(manifest.tokenFeeBps, "tokenFeeBps", 500);
  check(Array.isArray(manifest.feeExemptAccounts), "feeExemptAccounts must be an array");
  const feeExemptAccounts = manifest.feeExemptAccounts.map((v, i) => address(v, `feeExemptAccounts[${i}]`));
  check(Array.isArray(manifest.positionManagers), "positionManagers must be an array");
  const positionManagers = manifest.positionManagers.map((entry, i) => {
    check(entry && (entry.kind === "V3" || entry.kind === "V4"), `positionManagers[${i}] needs V3 or V4 kind`);
    check(typeof entry.officialSource === "string" && /^https:\/\/developers\.uniswap\.org\//.test(entry.officialSource),
      `positionManagers[${i}] needs a Uniswap deployment source`);
    return { address: address(entry.address, `positionManagers[${i}].address`), kind: entry.kind };
  });
  check(new Set(positionManagers.map((p) => p.address)).size === positionManagers.length,
    "duplicate position manager");

  const rpc = process.env.ELYSIUM_MAINNET_RPC_URL;
  check(typeof rpc === "string" && /^https:\/\//.test(rpc), "set ELYSIUM_MAINNET_RPC_URL to the official HTTPS RPC");
  const provider = new ethers.providers.JsonRpcProvider(rpc);
  const actualNetwork = await provider.getNetwork();
  check(actualNetwork.chainId === chainId,
    `RPC chain ID ${actualNetwork.chainId} differs from reviewed official chain ID ${chainId}`);
  const block = await provider.getBlockNumber();
  check(block > 0, "RPC has no blocks");
  for (const pm of positionManagers) {
    check(await provider.getCode(pm.address) !== "0x", `${pm.kind} manager ${pm.address} has no code`);
  }

  const managerArtifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const childArtifact = JSON.parse(fs.readFileSync(childArtifactPath, "utf8"));
  for (const [label, artifact] of [["manager", managerArtifact], ["child", childArtifact]]) {
    const debugPath = path.join(path.dirname(label === "manager" ? artifactPath : childArtifactPath), `${artifact.contractName}.dbg.json`);
    const debug = JSON.parse(fs.readFileSync(debugPath, "utf8"));
    const build = JSON.parse(fs.readFileSync(path.resolve(path.dirname(debugPath), debug.buildInfo), "utf8"));
    check(build.solcVersion === "0.8.30" && build.input.settings.evmVersion === "london" &&
      build.input.settings.optimizer.enabled && build.input.settings.optimizer.runs === 200,
      `${label} compiler settings differ from reviewed build`);
    for (const [source, input] of Object.entries(build.input.sources)) {
      if (source.startsWith("contracts/")) {
        check(fs.readFileSync(path.join(root, source), "utf8") === input.content,
          `${label} artifact is stale: ${source} differs from source on disk`);
      }
    }
    const outputRuntime = build.output.contracts[artifact.sourceName][artifact.contractName].evm.deployedBytecode.object;
    check(`0x${outputRuntime}`.toLowerCase() === artifact.deployedBytecode.toLowerCase(),
      `${label} artifact differs from compiler output`);
    check(/^0x[\da-fA-F]+$/.test(artifact.deployedBytecode), `${label} runtime artifact is missing`);
    const bytes = (artifact.deployedBytecode.length - 2) / 2;
    check(bytes <= 24576, `${label} exceeds EIP-170 runtime limit`);
    console.log(`${label} runtime: ${bytes} bytes; hash ${ethers.utils.keccak256(artifact.deployedBytecode)}`);
  }

  if (stage === "postdeploy") {
    const deployed = address(manifest.deployedManager, "deployedManager");
    const code = await provider.getCode(deployed);
    check(code !== "0x", "deployedManager has no code");
    check(ethers.utils.keccak256(code) === ethers.utils.keccak256(managerArtifact.deployedBytecode),
      "deployed manager runtime does not match the local release artifact");
    const manager = new ethers.Contract(deployed, managerArtifact.abi, provider);
    const [owner, receiver, nativeFee, tokenFee, enabled] = await Promise.all([
      manager.owner(), manager.feeReceiver(), manager.ethFee(), manager.tokenFeeBps(), manager.creationEnabled()
    ]);
    check(owner === expectedOwner, "deployed owner differs from manifest");
    check(receiver === expectedReceiver, "deployed fee receiver differs from manifest");
    check(nativeFee.eq(nativeFeeWei), "deployed native fee differs from manifest");
    check(tokenFee.toNumber() === tokenFeeBps, "deployed token fee differs from manifest");
    check(enabled, "new lock creation is disabled");
    for (const account of feeExemptAccounts) {
      check(await manager.isExemptFromFees(account), `fee exemption missing: ${account}`);
    }
    for (const pm of positionManagers) {
      const [kind, allowed] = await manager.positionManagerKind(pm.address);
      check(allowed && kind === (pm.kind === "V3" ? 1 : 2), `position manager configuration differs: ${pm.address}`);
    }
    console.log(`POSTDEPLOY CHECK PASSED on chain ${chainId}, block ${block}; manager ${deployed}`);
    console.log("Child runtime and end-to-end production transactions still need separate verification.");
  } else {
    console.log(`PREDEPLOY CHECK PASSED on chain ${chainId}, block ${block}`);
    console.log(`Expected owner ${expectedOwner}; fee receiver ${expectedReceiver}; native fee ${nativeFeeWei.toString()} wei; token fee ${tokenFeeBps} bps`);
    console.log("No deployment or production end-to-end test has been verified by this stage.");
  }
}

main().catch((error) => { console.error(`PREFLIGHT FAILED: ${error.message}`); process.exitCode = 1; });
