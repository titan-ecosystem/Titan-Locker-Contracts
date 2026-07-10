// Builds the linked creation bytecode + encoded constructor arg for
// TitanLockerManagerV2, using only fs + string ops (NO ethers) so it runs
// instantly even under heavy load. Output is fed to `cast send --create`.
const fs = require("fs");
const path = require("path");
const ROOT = path.join(__dirname, "..");

const DEPLOYER = "0x5C773302FBEED11fA59a6939f0354678738B02DB"; // constructor feeReceiver_ = deployer

const art = JSON.parse(
  fs.readFileSync(path.join(ROOT, "artifacts/contracts/TitanLockerManagerV2.sol/TitanLockerManagerV2.json"), "utf8")
);
const util = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments/robinhood/Util.json"), "utf8"));

let bc = art.bytecode; // "0x..." with __$<34hex>$__ Util placeholder
const utilAddr = util.address.replace(/^0x/, "").toLowerCase();
if (utilAddr.length !== 40) throw new Error("bad util address");

// only one library (Util); replace every placeholder occurrence with its address
bc = bc.replace(/__\$[0-9a-fA-F]{34}\$__/g, utilAddr);
if (bc.includes("__$")) throw new Error("unlinked library placeholder remains");

// abi-encode the single address constructor arg: 12 zero bytes + 20-byte address
const arg = "000000000000000000000000" + DEPLOYER.replace(/^0x/, "").toLowerCase();
const initcode = bc + arg;

fs.writeFileSync(path.join(ROOT, "scripts/.initcode"), initcode);
console.log("util linked:", bc.toLowerCase().includes(utilAddr));
console.log("initcode bytes:", (initcode.length - 2) / 2);
console.log("deployedBytecode bytes (expected on-chain):", (art.deployedBytecode.replace(/__\$[0-9a-fA-F]{34}\$__/g, utilAddr).length - 2) / 2);
