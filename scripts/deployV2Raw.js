// Controlled raw deploy of TitanLockerManagerV2 to Robinhood, robust to the
// flaky ethers/hardhat provider: signs locally with ethers, sends every RPC via
// node fetch with a hard timeout, sets gas explicitly (no estimate/auto-detect
// round-trips that can wedge), links the Util library from the artifact, and
// VERIFIES on-chain code == artifact deployedBytecode before declaring success.
// Run: node scripts/deployV2Raw.js
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const ROOT = path.join(__dirname, "..");

function readEnv() {
  const env = {};
  for (const line of fs.readFileSync(path.join(ROOT, ".env"), "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return env;
}

async function rpc(url, method, params) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 15000);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", method, params, id: 1 }),
      signal: ctrl.signal,
    });
    const j = await res.json();
    if (j.error) throw new Error(method + ": " + j.error.message);
    return j.result;
  } finally {
    clearTimeout(t);
  }
}

function linkBytecode(bytecode, linkReferences, libs) {
  let bc = bytecode;
  for (const file in linkReferences) {
    for (const lib in linkReferences[file]) {
      const addr = libs[lib];
      if (!addr) throw new Error("missing library address for " + lib);
      const clean = addr.replace(/^0x/, "").toLowerCase();
      if (clean.length !== 40) throw new Error("bad library address " + addr);
      for (const ref of linkReferences[file][lib]) {
        const s = 2 + ref.start * 2; // +2 for "0x"
        bc = bc.slice(0, s) + clean + bc.slice(s + ref.length * 2);
      }
    }
  }
  if (bc.includes("__$")) throw new Error("bytecode still has an unlinked library placeholder");
  return bc;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const env = readEnv();
  const url = env.ROBINHOOD_RPC_URL;
  const wallet = new ethers.Wallet(env.DEPLOYER_PRIVATE_KEY);
  const deployer = wallet.address;

  const art = JSON.parse(
    fs.readFileSync(path.join(ROOT, "artifacts/contracts/TitanLockerManagerV2.sol/TitanLockerManagerV2.json"), "utf8")
  );
  const util = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments/robinhood/Util.json"), "utf8"));

  const linked = linkBytecode(art.bytecode, art.linkReferences, { Util: util.address });
  const factory = new ethers.ContractFactory(art.abi, linked, wallet);
  const unsigned = factory.getDeployTransaction(deployer); // constructor(feeReceiver_ = deployer)
  const data = ethers.utils.hexlify(unsigned.data);

  const chainId = parseInt(await rpc(url, "eth_chainId", []), 16);
  if (chainId !== 4663) throw new Error("unexpected chainId " + chainId);
  const nonce = parseInt(await rpc(url, "eth_getTransactionCount", [deployer, "pending"]), 16);
  const gasPrice = ethers.BigNumber.from(await rpc(url, "eth_gasPrice", [])).mul(2); // 2x headroom
  let gasLimit;
  try {
    const est = await rpc(url, "eth_estimateGas", [{ from: deployer, data }]);
    gasLimit = ethers.BigNumber.from(est).mul(12).div(10); // +20%
  } catch (e) {
    gasLimit = ethers.BigNumber.from(5_000_000);
  }

  const bal = ethers.BigNumber.from(await rpc(url, "eth_getBalance", [deployer, "latest"]));
  const maxCost = gasPrice.mul(gasLimit);
  console.log("deployer:", deployer);
  console.log("balance:", ethers.utils.formatEther(bal), "ETH");
  console.log("gasPrice:", ethers.utils.formatUnits(gasPrice, "gwei"), "gwei  gasLimit:", gasLimit.toString());
  console.log("max cost:", ethers.utils.formatEther(maxCost), "ETH");
  if (bal.lt(maxCost)) throw new Error("insufficient balance for max gas cost");

  const signed = await wallet.signTransaction({
    type: 0,
    chainId,
    nonce,
    gasPrice: gasPrice.toHexString(),
    gasLimit: gasLimit.toHexString(),
    to: undefined,
    value: "0x0",
    data,
  });

  console.log("broadcasting deploy tx...");
  const txHash = await rpc(url, "eth_sendRawTransaction", [signed]);
  console.log("tx hash:", txHash);

  let receipt = null;
  for (let i = 0; i < 80; i++) {
    receipt = await rpc(url, "eth_getTransactionReceipt", [txHash]);
    if (receipt) break;
    await sleep(3000);
  }
  if (!receipt) throw new Error("no receipt after ~4min; tx=" + txHash);

  const ok = parseInt(receipt.status, 16) === 1;
  console.log("status:", ok ? "SUCCESS" : "FAILED", " gasUsed:", parseInt(receipt.gasUsed, 16));
  if (!ok) throw new Error("deploy tx reverted; tx=" + txHash);

  const address = receipt.contractAddress;
  console.log("deployed TitanLockerManagerV2 at:", address);

  // integrity check: on-chain runtime code must equal the linked deployedBytecode
  const onchain = (await rpc(url, "eth_getCode", [address, "latest"])).toLowerCase();
  const expected = linkBytecode(art.deployedBytecode, art.deployedLinkReferences || art.linkReferences, {
    Util: util.address,
  }).toLowerCase();
  const codeMatches = onchain === expected;
  console.log("on-chain code matches artifact:", codeMatches);
  if (!codeMatches) throw new Error("DEPLOYED CODE DOES NOT MATCH ARTIFACT - do not use this deployment");

  fs.writeFileSync(
    path.join(ROOT, "deployments/robinhood/TitanLockerManagerV2.json"),
    JSON.stringify(
      {
        address,
        abi: art.abi,
        transactionHash: txHash,
        args: [deployer],
        libraries: { Util: util.address },
        receipt: { from: receipt.from, contractAddress: address, blockNumber: parseInt(receipt.blockNumber, 16), gasUsed: parseInt(receipt.gasUsed, 16), status: 1 },
      },
      null,
      2
    )
  );
  console.log("saved deployments/robinhood/TitanLockerManagerV2.json");
  console.log("DEPLOY OK");
})().catch((e) => {
  console.error("DEPLOY ERROR:", e.message);
  process.exit(1);
});
