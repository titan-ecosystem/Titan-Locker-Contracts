// End-to-end LP demo: deploys a fresh test token, pairs it with native ETH on
// Robinhood Chain's live Uniswap V2 fork (0.00001 ETH worth of liquidity),
// then locks the resulting LP tokens in Titan Locker for 1 month, paying the
// fee in-kind (LP tokens) rather than in ETH.
//
// Uses the real, already-deployed router/factory on Robinhood Chain (verified
// live on-chain: router.factory() and router.WETH() both resolve correctly,
// and the factory already has hundreds of real pairs) - not a mock DEX.
//
// Usage: npx hardhat run scripts/createLpDemoLock.js --network robinhood
const hre = require("hardhat");

const ROUTER_ADDRESS = "0x89e5db8b5aa49aa85ac63f691524311aeb649eba";
const FACTORY_ADDRESS = "0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f";
const WETH_ADDRESS = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73";

const ETH_LIQUIDITY = "0.00001";
const TOKEN_SUPPLY = 1_000_000; // whole tokens, scaled by decimals in TestERC20's constructor
const TOKEN_LIQUIDITY = 100_000; // whole tokens paired against the ETH side
const LOCK_SECONDS = 30 * 24 * 60 * 60; // 1 month

const ROUTER_ABI = [
  "function addLiquidityETH(address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity)",
];
const FACTORY_ABI = ["function getPair(address tokenA, address tokenB) external view returns (address pair)"];
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
];

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const manager = await hre.ethers.getContract("TitanLockerManagerV1");

  console.log("=== 1. Deploying test ERC20 ===");
  const TestERC20 = await hre.ethers.getContractFactory("TestERC20");
  const token = await TestERC20.deploy("Titan LP Demo Token", "TLPD", TOKEN_SUPPLY);
  await token.deployed();
  console.log("Token deployed at:", token.address);

  console.log("\n=== 2. Adding liquidity via the live router ===");
  const router = new hre.ethers.Contract(ROUTER_ADDRESS, ROUTER_ABI, signer);
  const factory = new hre.ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, signer);

  const tokenLiquidityRaw = hre.ethers.utils.parseUnits(String(TOKEN_LIQUIDITY), 18);
  await (await token.approve(ROUTER_ADDRESS, tokenLiquidityRaw)).wait();

  const deadline = Math.floor(Date.now() / 1000) + 20 * 60; // 20 minutes from now
  const addLiqTx = await router.addLiquidityETH(
    token.address,
    tokenLiquidityRaw,
    0, // amountTokenMin - brand new pair, no existing reserves to slip against
    0, // amountETHMin
    signer.address,
    deadline,
    { value: hre.ethers.utils.parseEther(ETH_LIQUIDITY) }
  );
  await addLiqTx.wait();
  console.log(`Added ${TOKEN_LIQUIDITY} TLPD + ${ETH_LIQUIDITY} ETH as liquidity`);

  const pairAddress = await factory.getPair(token.address, WETH_ADDRESS);
  console.log("LP pair (LP token) address:", pairAddress);

  const lpToken = new hre.ethers.Contract(pairAddress, ERC20_ABI, signer);
  const lpBalance = await lpToken.balanceOf(signer.address);
  console.log("LP tokens received:", hre.ethers.utils.formatUnits(lpBalance), "LP");

  console.log("\n=== 3. Locking LP tokens for 1 month (fee paid in LP tokens) ===");
  await (await lpToken.approve(manager.address, lpBalance)).wait();

  const latestBlock = await hre.ethers.provider.getBlock("latest");
  const unlockTime = latestBlock.timestamp + LOCK_SECONDS;

  const createTx = await manager.createTokenLocker(pairAddress, lpBalance, unlockTime);
  await createTx.wait();

  const lockId = Number(await manager.tokenLockerCount()) - 1;
  const lockerAddress = await manager.getTokenLockAddress(lockId);

  console.log("Lock created - id:", lockId, "address:", lockerAddress);
  console.log("Unlocks at:", new Date(unlockTime * 1000).toISOString(), "(in 1 month)");
  console.log(`\nView it at: /lock/${lockId}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
