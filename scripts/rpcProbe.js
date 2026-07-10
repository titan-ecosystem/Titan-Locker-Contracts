// Robust RPC probe: no dotenv, no ethers provider auto-detect. Parses .env
// itself, derives the deployer address, and queries balance via node's built-in
// fetch with a hard AbortController timeout so it can never wedge.
// Run: node scripts/rpcProbe.js
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers"); // resolves from this file's node_modules

function readEnv() {
  const env = {};
  const txt = fs.readFileSync(path.join(__dirname, "..", ".env"), "utf8");
  for (const line of txt.split("\n")) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return env;
}

async function rpc(url, method, params) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 12000);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", method, params, id: 1 }),
      signal: ctrl.signal,
    });
    const j = await res.json();
    if (j.error) throw new Error(j.error.message);
    return j.result;
  } finally {
    clearTimeout(t);
  }
}

(async () => {
  const env = readEnv();
  const url = env.ROBINHOOD_RPC_URL;
  const pk = env.DEPLOYER_PRIVATE_KEY;
  if (!url || !pk) throw new Error("ROBINHOOD_RPC_URL or DEPLOYER_PRIVATE_KEY missing in .env");

  const addr = new ethers.Wallet(pk).address;
  const chainId = await rpc(url, "eth_chainId", []);
  const balHex = await rpc(url, "eth_getBalance", [addr, "latest"]);
  const bal = ethers.BigNumber.from(balHex);

  console.log("chainId:", parseInt(chainId, 16));
  console.log("deployer:", addr);
  console.log("balance:", ethers.utils.formatEther(bal), "ETH");
  console.log("VERDICT:", bal.gt(0) ? "FUNDED - deployable" : "ZERO BALANCE - fund deployer first");
})().catch((e) => {
  console.error("PROBE ERROR:", e.message);
  process.exit(1);
});
