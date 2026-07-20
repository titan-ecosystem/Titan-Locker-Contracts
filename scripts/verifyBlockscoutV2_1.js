// Direct API verification against Blockscout's classic Etherscan-compatible
// endpoint - same approach as verifyBlockscout.js (see that file for why).
// Verifies TitanLockerManagerV2_1, the ContractWolf-audit-fixed redeploy.
//
// Usage: node scripts/verifyBlockscoutV2_1.js
require("dotenv").config();
const fs = require("fs");
const https = require("https");
const { ethers } = require("ethers");

const API_URL = "https://robinhoodchain.blockscout.com/api";
const API_KEY = process.env.BLOCKSCOUT_API_KEY || "";
const COMPILER_VERSION = "v0.8.30+commit.73712a01";

// Exact deployment-time solc input for TitanLockerManagerV2_1 (matches its
// recorded solcInputHash) - required for an exact metadata-hash match.
const solcInput = JSON.parse(
  fs.readFileSync("deployments/robinhood/solcInputs/354a05b09a99ca544a36cdd4f1479b5a.json")
);

const CONTRACTS = [
  {
    name: "TitanLockerManagerV2_1",
    address: "0x102a70bDA2C833b3483A2eE55C14c7ea0fb7A01B",
    contractName: "contracts/TitanLockerManagerV2.sol:TitanLockerManagerV2",
    constructorArgs: ethers.utils.defaultAbiCoder
      .encode(["address"], ["0x5C773302FBEED11fA59a6939f0354678738B02DB"])
      .slice(2), // strip 0x - Etherscan-style API wants it bare
    libraries: { "contracts/Util.sol": { Util: "0xFBfa1ce526f98deC2251D44d1DaF7c599223aFe6" } },
  },
];

function postForm(url, fields) {
  return new Promise((resolve, reject) => {
    const body = new URLSearchParams(fields).toString();
    const { hostname, pathname, search } = new URL(url);
    const req = https.request(
      {
        hostname,
        path: pathname + search,
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => resolve(data));
      }
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function checkStatus(guid) {
  const url = `${API_URL}?module=contract&action=checkverifystatus&guid=${guid}&apikey=${API_KEY}`;
  const res = await new Promise((resolve, reject) => {
    https.get(url, (r) => {
      let data = "";
      r.on("data", (c) => (data += c));
      r.on("end", () => resolve(data));
    }).on("error", reject);
  });
  return JSON.parse(res);
}

async function verifyContract(c) {
  console.log(`\n=== Verifying ${c.name} at ${c.address} ===`);

  const input = JSON.parse(JSON.stringify(solcInput)); // deep clone, don't mutate shared object
  if (c.libraries) {
    input.settings.libraries = c.libraries;
  }

  const fields = {
    module: "contract",
    action: "verifysourcecode",
    contractaddress: c.address,
    sourceCode: JSON.stringify(input),
    codeformat: "solidity-standard-json-input",
    contractname: c.contractName,
    compilerversion: COMPILER_VERSION,
    apikey: API_KEY,
  };
  if (c.constructorArgs) {
    fields.constructorArguements = c.constructorArgs;
  }

  const submitRaw = await postForm(API_URL, fields);
  let submitResult;
  try {
    submitResult = JSON.parse(submitRaw);
  } catch (e) {
    console.log("Non-JSON response from submit:", submitRaw.slice(0, 500));
    return;
  }
  console.log("Submit response:", JSON.stringify(submitResult));

  if (submitResult.status !== "1") {
    console.log(`FAILED to submit ${c.name}:`, submitResult.result);
    return;
  }

  const guid = submitResult.result;
  console.log("Polling verification status (guid:", guid, ")...");

  for (let i = 0; i < 10; i++) {
    await sleep(5000);
    const status = await checkStatus(guid);
    console.log("  ->", JSON.stringify(status));
    if (status.result && status.result !== "Pending in queue") {
      console.log(`${c.name}: ${status.result}`);
      return;
    }
  }
  console.log(`${c.name}: still pending after polling window, check manually later`);
}

async function main() {
  for (const c of CONTRACTS) {
    await verifyContract(c);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
