require("dotenv").config();
const { utils } = require("ethers");
const fs = require("fs");

require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-etherscan");
require("hardhat-deploy");
require("hardhat-gas-reporter");
require("solidity-coverage");

const { isAddress, getAddress, formatUnits, parseUnits } = utils;

// defaults to the local Hardhat network so `yarn test`/`yarn deploy` never
// accidentally target a live chain without an explicit --network flag.
const defaultNetwork = "localhost";

function mnemonic() {
  try {
    return fs.readFileSync("./mnemonic.txt").toString().trim();
  } catch (e) {
    if (defaultNetwork !== "localhost") {
      console.log(
        "WARNING: No mnemonic file created for a deploy account. Try `yarn generate` and then `yarn account`."
      );
    }
  }
  return "";
}

// Prefers a single raw private key (DEPLOYER_PRIVATE_KEY in .env, never
// committed) over the mnemonic file, so either style of deploy account works.
// Falls back to an empty account list (not an empty-string mnemonic, which
// Hardhat treats as invalid and refuses to even initialize the network for)
// so read-only commands - `hardhat verify`, scripts that only ever call view
// functions - still work with no deploy key configured at all.
function deployerAccounts() {
  if (process.env.DEPLOYER_PRIVATE_KEY) {
    const pk = process.env.DEPLOYER_PRIVATE_KEY.trim();
    return [pk.startsWith("0x") ? pk : `0x${pk}`];
  }
  const seedPhrase = mnemonic();
  return seedPhrase ? { mnemonic: seedPhrase } : [];
}

module.exports = {
  defaultNetwork,

  gasReporter: {
    currency: "USD",
    coinmarketcap: process.env.COINMARKETCAP || null,
  },

  // Copy example.env to .env and fill in the networks you actually deploy to.
  networks: {
    hardhat: {
      // solidity-coverage's instrumentation inflates bytecode past the real
      // EIP-170 size limit; this only relaxes the LOCAL in-memory network
      // used for tests/coverage, real deployments still enforce the limit.
      allowUnlimitedContractSize: true,
    },
    localhost: {
      url: "http://localhost:8545",
    },
    eth: {
      url: "https://rpc.ankr.com/eth",
      accounts: deployerAccounts(),
    },
    bsc: {
      url: "https://bsc-dataseed.binance.org/",
      accounts: deployerAccounts(),
    },
    bsctest: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      accounts: deployerAccounts(),
    },
    polygon: {
      url: "https://polygon-rpc.com/",
      accounts: deployerAccounts(),
    },
    mumbai: {
      url: "https://rpc-mumbai.maticvigil.com/",
      accounts: deployerAccounts(),
    },
    arbitrum: {
      url: "https://arb1.arbitrum.io/rpc",
      accounts: deployerAccounts(),
    },
    base: {
      url: "https://developer-access-mainnet.base.org/",
      accounts: deployerAccounts(),
    },
    avax: {
      url: "https://api.avax.network/ext/bc/C/rpc",
      accounts: deployerAccounts(),
    },
    optimism: {
      url: "https://mainnet.optimism.io",
      accounts: deployerAccounts(),
    },
    robinhood: {
      // no public RPC for this chain - set ROBINHOOD_RPC_URL in your local
      // .env (never commit the real URL, it carries a provider auth token)
      url: process.env.ROBINHOOD_RPC_URL || "",
      chainId: 4663,
      accounts: deployerAccounts(),
    },
  },

  solidity: {
    compilers: [
      {
        version: "0.8.30",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          // this Hardhat/network toolchain predates the Shanghai hardfork's
          // PUSH0 opcode; pin codegen to a hardfork every target chain supports.
          evmVersion: "london",
        },
      },
    ],
  },

  namedAccounts: {
    deployer: {
      default: 0,
    },
  },

  etherscan: {
    apiKey: {
      base: process.env.ETHERSCAN_API_KEY_BASE || process.env.ETHERSCAN_API_KEY,
      // Blockscout accepts any non-empty string, but uses a real key if set
      robinhood: process.env.BLOCKSCOUT_API_KEY || "no-api-key-needed",
    },
    customChains: [
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
      {
        network: "robinhood",
        chainId: 4663,
        urls: {
          apiURL: "https://robinhoodchain.blockscout.com/api",
          browserURL: "https://robinhoodchain.blockscout.com",
        },
      },
    ],
  },
};

task("accounts", "Prints the list of accounts", async (_, { ethers }) => {
  const accounts = await ethers.provider.listAccounts();
  accounts.forEach((account) => console.log(account));
});

task("blockNumber", "Prints the block number", async (_, { ethers }) => {
  console.log(await ethers.provider.getBlockNumber());
});

async function addr(ethers, addr) {
  if (isAddress(addr)) return getAddress(addr);
  const accounts = await ethers.provider.listAccounts();
  if (accounts[addr] !== undefined) return accounts[addr];
  throw `Could not normalize address: ${addr}`;
}

task("balance", "Prints an account's balance")
  .addPositionalParam("account", "The account's address")
  .setAction(async (taskArgs, { ethers }) => {
    const balance = await ethers.provider.getBalance(await addr(ethers, taskArgs.account));
    console.log(formatUnits(balance, "ether"), "ETH");
  });

task("generate", "Create a mnemonic for deploys", async () => {
  const bip39 = require("bip39");
  const mnemonic = bip39.generateMnemonic();
  fs.writeFileSync("./mnemonic.txt", mnemonic.toString());
  console.log("Mnemonic written to ./mnemonic.txt - keep it out of version control.");
});

task("account", "Prints the deployer account's address and balance across configured networks", async (_, { ethers, config }) => {
  let address;

  if (process.env.DEPLOYER_PRIVATE_KEY) {
    const pk = process.env.DEPLOYER_PRIVATE_KEY.trim();
    address = new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`).address;
  } else {
    const hdkey = require("ethereumjs-wallet/hdkey");
    const bip39 = require("bip39");
    const localMnemonic = fs.readFileSync("./mnemonic.txt").toString().trim();
    const seed = await bip39.mnemonicToSeed(localMnemonic);
    const wallet = hdkey.fromMasterSeed(seed).derivePath("m/44'/60'/0'/0/0").getWallet();
    const EthUtil = require("ethereumjs-util");
    address = "0x" + EthUtil.privateToAddress(wallet._privKey).toString("hex");
  }
  console.log("Deployer account:", address);

  for (const name in config.networks) {
    const networkUrl = config.networks[name].url;
    if (!networkUrl) continue;
    try {
      const provider = new ethers.providers.JsonRpcProvider(networkUrl);
      const balance = await provider.getBalance(address);
      console.log(` -- ${name}: ${ethers.utils.formatEther(balance)} ETH`);
    } catch (e) {
      // network unreachable; skip
    }
  }
});
