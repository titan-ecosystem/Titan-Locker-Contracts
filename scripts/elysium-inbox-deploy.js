#!/usr/bin/env node
// Deploy the regular Elysium manager through HyperEVM's delayed Inbox.
// Default mode is read-only. `execute` sends parent-chain transactions.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { ethers } = require('ethers');

const root = path.resolve(__dirname, '..');
require('dotenv').config({ path: path.join(root, '.env') });
const manifestPath = path.join(root, 'deployments/elysium-mainnet.release.json');
const statePath = path.join(root, '.elysium-inbox-state.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const util = JSON.parse(fs.readFileSync(path.join(root, 'artifacts/contracts/Util.sol/Util.json')));
const manager = JSON.parse(fs.readFileSync(path.join(root, 'artifacts/contracts/TitanLockerManagerV2.sol/TitanLockerManagerV2.json')));
const inboxAbi = ['function sendL2Message(bytes messageData) returns (uint256)'];
const managerAbi = [
  'function owner() view returns (address)',
  'function feeReceiver() view returns (address)',
  'function ethFee() view returns (uint256)',
  'function tokenFeeBps() view returns (uint16)',
  'function creationEnabled() view returns (bool)',
  'function setCreationEnabled(bool)',
  'function setEthFee(uint256)',
];

function ensure(value, message) { if (!value) throw new Error(message); }
function eq(a, b) { return String(a).toLowerCase() === String(b).toLowerCase(); }
function readState() { return fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, 'utf8')) : {}; }
function writeState(state) {
  const temp = statePath + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(state, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(temp, statePath);
}
function saveManifest() {
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
}
function linkUtil(artifact, field, utilAddress) {
  let code = artifact[field].slice(2);
  const refs = (field === 'bytecode' ? artifact.linkReferences : artifact.deployedLinkReferences)['contracts/Util.sol']?.Util || [];
  for (const ref of refs) {
    ensure(ref.length === 20, 'unexpected Util link length');
    const offset = ref.start * 2;
    code = code.slice(0, offset) + utilAddress.slice(2).toLowerCase() + code.slice(offset + 40);
  }
  ensure(/^[a-fA-F0-9]+$/.test(code), 'unresolved library reference');
  return '0x' + code;
}
function expectedUtilRuntime(address) {
  // Solidity libraries begin with PUSH20 of their own deployed address.
  return '0x73' + address.slice(2).toLowerCase() + util.deployedBytecode.slice(44);
}
async function waitForChild(provider, hash) {
  const deadline = Date.now() + 20 * 60 * 1000;
  while (Date.now() < deadline) {
    const receipt = await provider.getTransactionReceipt(hash);
    if (receipt) {
      ensure(receipt.status === 1, `child transaction reverted: ${hash}`);
      return receipt;
    }
    await new Promise(resolve => setTimeout(resolve, 10000));
  }
  throw new Error(`child transaction still pending: ${hash}; inspect the saved state and Inbox watcher before resuming`);
}
async function sendChildTx(label, data, to, context) {
  const { child, parent, childWallet, parentWallet, inbox, state } = context;
  if (state[label]) {
    ensure(state[label].l1Hash, `${label} was prepared but its parent submission needs manual reconciliation`);
    const receipt = await waitForChild(child, state[label].l2Hash);
    return receipt;
  }
  const nonce = await child.getTransactionCount(childWallet.address, 'latest');
  const estimated = await child.estimateGas({ from: childWallet.address, to, data, value: 0 });
  const gasLimit = estimated.mul(125).div(100).add(50000);
  const gasPrice = await child.getGasPrice();
  const feeCap = gasPrice.mul(5);
  const childBalance = await child.getBalance(childWallet.address);
  ensure(childBalance.gte(gasLimit.mul(feeCap)), 'insufficient child HYPE for signed transaction fee cap');
  // Estimate with nonzero, unsigned bytes. A signed child transaction is only
  // supplied to the actual Inbox transaction, never to an estimate endpoint.
  const dummyBytes = (data.length - 2) / 2 + 220;
  const estimateData = inbox.interface.encodeFunctionData('sendL2Message', ['0x' + 'ff'.repeat(dummyBytes)]);
  const parentGas = await parent.estimateGas({ from: parentWallet.address, to: manifest.inbox, data: estimateData });
  const parentBalance = await parent.getBalance(parentWallet.address);
  const parentGasPrice = await parent.getGasPrice();
  ensure(parentBalance.gte(parentGas.mul(parentGasPrice).mul(2)), 'insufficient parent HYPE for Inbox submission');
  const raw = await childWallet.signTransaction({
    chainId: manifest.chainId, type: 2, nonce, to, data, value: 0,
    gasLimit, maxFeePerGas: feeCap, maxPriorityFeePerGas: 0,
  });
  const childHash = ethers.utils.keccak256(raw);
  const calldata = inbox.interface.encodeFunctionData('sendL2Message', [raw]);
  state[label] = { l2Hash: childHash, nonce, l1Hash: null };
  writeState(state);
  const parentTx = await parentWallet.sendTransaction({
    to: manifest.inbox, data: calldata, gasLimit: parentGas.mul(125).div(100),
  });
  state[label].l1Hash = parentTx.hash;
  writeState(state);
  console.log(`${label} posted: parent ${parentTx.hash}; child ${childHash}`);
  const parentReceipt = await parentTx.wait(1);
  ensure(parentReceipt.status === 1, `parent Inbox transaction reverted: ${parentTx.hash}`);
  return waitForChild(child, childHash);
}
function requireMergedCleanSource() {
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  ensure(git('branch', '--show-current') === 'main', 'deployment requires the merged main branch');
  ensure(git('rev-parse', 'HEAD') === git('rev-parse', 'origin/main'), 'local main differs from origin/main');
  ensure(!git('status', '--porcelain', '--', 'contracts', 'scripts'), 'release sources are dirty');
}
async function main() {
  const mode = process.argv[2] || 'preflight';
  ensure(mode === 'preflight' || mode === 'execute', 'use preflight or execute');
  execFileSync('node', [path.join(__dirname, 'elysium-mainnet-preflight.js'), 'predeploy'], {
    cwd: root, stdio: 'inherit', env: process.env,
  });
  if (mode === 'preflight') {
    console.log('Inbox deployment is prepared; no transaction was signed or sent.');
    return;
  }
  requireMergedCleanSource();
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  ensure(key, 'DEPLOYER_PRIVATE_KEY is missing');
  const parent = new ethers.providers.JsonRpcProvider(process.env.ELYSIUM_PARENT_RPC_URL);
  const child = new ethers.providers.JsonRpcProvider(process.env.ELYSIUM_MAINNET_RPC_URL);
  const childWallet = new ethers.Wallet(key, child);
  const parentWallet = new ethers.Wallet(key, parent);
  ensure(eq(childWallet.address, manifest.owner), 'deployer does not match release owner');
  const inbox = new ethers.Contract(manifest.inbox, inboxAbi, parentWallet);
  const state = readState();
  const context = { child, parent, childWallet, parentWallet, inbox, state };

  if (!manifest.deployedUtil) {
    const utilAddress = ethers.utils.getContractAddress({
      from: childWallet.address, nonce: state.util?.nonce ?? await child.getTransactionCount(childWallet.address),
    });
    const receipt = await sendChildTx('util', util.bytecode, null, context);
    ensure(eq(receipt.contractAddress, utilAddress), 'Util deployed at an unexpected address');
    ensure(eq(await child.getCode(utilAddress), expectedUtilRuntime(utilAddress)), 'Util runtime differs');
    manifest.deployedUtil = utilAddress;
    saveManifest();
  }
  ensure(eq(await child.getCode(manifest.deployedUtil), expectedUtilRuntime(manifest.deployedUtil)), 'Util runtime differs');

  if (!manifest.deployedManager) {
    const creation = linkUtil(manager, 'bytecode', manifest.deployedUtil);
    const factory = new ethers.ContractFactory(manager.abi, creation);
    const deployData = factory.getDeployTransaction(manifest.feeReceiver).data;
    const managerAddress = ethers.utils.getContractAddress({
      from: childWallet.address, nonce: state.manager?.nonce ?? await child.getTransactionCount(childWallet.address),
    });
    const receipt = await sendChildTx('manager', deployData, null, context);
    ensure(eq(receipt.contractAddress, managerAddress), 'manager deployed at an unexpected address');
    ensure(eq(await child.getCode(managerAddress), linkUtil(manager, 'deployedBytecode', manifest.deployedUtil)), 'manager runtime differs');
    manifest.deployedManager = managerAddress;
    saveManifest();
  }
  const deployed = new ethers.Contract(manifest.deployedManager, managerAbi, child);
  ensure(eq(await deployed.owner(), manifest.owner), 'deployed manager owner differs');
  ensure(eq(await deployed.feeReceiver(), manifest.feeReceiver), 'deployed fee receiver differs');
  ensure(Number(await deployed.tokenFeeBps()) === manifest.tokenFeeBps, 'token fee differs');

  if ((await deployed.ethFee()).eq(manifest.nativeFeeWei) && await deployed.creationEnabled()) {
    console.log(`Elysium manager already configured: ${manifest.deployedManager}`);
    execFileSync('node', [path.join(__dirname, 'elysium-mainnet-preflight.js'), 'postdeploy'], {
      cwd: root, stdio: 'inherit', env: process.env,
    });
    return;
  }

  if (!state.disableConfirmed && await deployed.creationEnabled()) {
    await sendChildTx('disableTx', deployed.interface.encodeFunctionData('setCreationEnabled', [false]), manifest.deployedManager, context);
  }
  ensure(!(await deployed.creationEnabled()), 'creation did not disable');
  state.disableConfirmed = true;
  writeState(state);

  if (!(await deployed.ethFee()).eq(manifest.nativeFeeWei)) {
    await sendChildTx('fee', deployed.interface.encodeFunctionData('setEthFee', [manifest.nativeFeeWei]), manifest.deployedManager, context);
  }
  ensure((await deployed.ethFee()).eq(manifest.nativeFeeWei), 'native fee did not update');
  if (!(await deployed.creationEnabled())) {
    await sendChildTx('enabled', deployed.interface.encodeFunctionData('setCreationEnabled', [true]), manifest.deployedManager, context);
  }
  ensure(await deployed.creationEnabled(), 'creation did not enable');
  console.log(`Elysium manager configured: ${manifest.deployedManager}`);
  execFileSync('node', [path.join(__dirname, 'elysium-mainnet-preflight.js'), 'postdeploy'], {
    cwd: root, stdio: 'inherit', env: process.env,
  });
}
main().catch(error => { console.error(`INBOX RELEASE STOPPED: ${error.message}`); process.exitCode = 1; });
