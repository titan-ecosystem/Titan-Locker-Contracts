const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

describe("Util.sol", () => {
  let erc20;
  let tokenA, tokenB;
  let mockPair;
  let utilContract;

  before(async () => {
    const ERC20 = await ethers.getContractFactory("TestERC20");
    // constructor(string memory name_, string memory symbol_, uint256 totalSupply_)
    erc20 = await ERC20.deploy("ERC20", "ERC20", 1000000);
    tokenA = await ERC20.deploy("Token A", "TOKA", 1000000);
    tokenB = await ERC20.deploy("Token B", "TOKB", 1000000);
  });

  it("Should deploy Util", async () => {
    const UtilContract = await ethers.getContractFactory("Util");
    utilContract = await UtilContract.deploy();
  });

  describe("getTokenData(address address_)", () => {
    it("Token should be named ERC20", async () => {
      const tokenData = await utilContract.getTokenData(erc20.address);

      expect(tokenData.name).to.equal("ERC20");
    });

    it("Should report the caller's balance", async () => {
      const [deployer] = await ethers.getSigners();
      const tokenData = await utilContract.getTokenData(erc20.address);
      expect(tokenData.balance).to.equal(await erc20.balanceOf(deployer.address));
    });
  });

  describe("isLpToken(address address_)", () => {
    it("Should return false for ERC20 token", async () => {
      expect(await utilContract.isLpToken(erc20.address)).to.equal(false);
    });

    it("Should return true for a mock LP pair", async () => {
      const MockPair = await ethers.getContractFactory("MockUniswapV2Pair");
      mockPair = await MockPair.deploy(tokenA.address, tokenB.address, 111, 222, 1000000);

      expect(await utilContract.isLpToken(mockPair.address)).to.equal(true);
    });
  });

  describe("getLpData(address address_)", () => {
    it("Should return the pair's tokens, balances, and cumulative prices", async () => {
      await tokenA.transfer(mockPair.address, 1000);
      await tokenB.transfer(mockPair.address, 2000);

      const lpData = await utilContract.getLpData(mockPair.address);

      expect(lpData.token0).to.equal(tokenA.address);
      expect(lpData.token1).to.equal(tokenB.address);
      expect(lpData.balance0).to.equal(1000);
      expect(lpData.balance1).to.equal(2000);
      expect(lpData.price0).to.equal(111);
      expect(lpData.price1).to.equal(222);
    });

    it("Should revert when called on a non-LP token", async () => {
      await expect(utilContract.getLpData(erc20.address)).to.be.reverted;
    });
  });
});
