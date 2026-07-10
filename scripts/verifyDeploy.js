// Post-deploy integrity check (no ethers): on-chain runtime code must equal the
// linked artifact deployedBytecode. Uses node's built-in fetch.
const fs = require("fs");
const path = require("path");
const ROOT = path.join(__dirname, "..");
const ADDR = "0x26b0654a0756dcd036d4e7215324f3d2be34d79e";

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
  const t = setTimeout(() => ctrl.abort(), 12000);
  try {
    const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", method, params, id: 1 }), signal: ctrl.signal });
    const j = await res.json();
    if (j.error) throw new Error(method + ": " + j.error.message);
    return j.result;
  } finally { clearTimeout(t); }
}

(async () => {
  const env = readEnv();
  const art = JSON.parse(fs.readFileSync(path.join(ROOT, "artifacts/contracts/TitanLockerManagerV2.sol/TitanLockerManagerV2.json"), "utf8"));
  const util = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments/robinhood/Util.json"), "utf8"));
  const utilAddr = util.address.replace(/^0x/, "").toLowerCase();
  const expected = art.deployedBytecode.replace(/__\$[0-9a-fA-F]{34}\$__/g, utilAddr).toLowerCase();
  const onchain = (await rpc(env.ROBINHOOD_RPC_URL, "eth_getCode", [ADDR, "latest"])).toLowerCase();
  console.log("expected code bytes:", (expected.length - 2) / 2);
  console.log("on-chain code bytes:", (onchain.length - 2) / 2);
  console.log("BYTECODE MATCHES ARTIFACT:", onchain === expected);
})().catch((e) => { console.error("VERIFY ERROR:", e.message); process.exit(1); });
