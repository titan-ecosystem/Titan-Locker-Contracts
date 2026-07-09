const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

const KIND = { ERC20: 0, UNIV3: 1, UNIV4: 2 };
const ZERO = ethers.constants.AddressZero;

async function futureUnlock(secondsFromNow = 3600) {
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  return now + secondsFromNow;
}

describe("TitanLockerV2.sol", () => {
  let utilContract, manager, erc20;
  let deployer, feeReceiver, other;

  before(async () => {
    [deployer, feeReceiver, other] = await ethers.getSigners();

    const UtilContract = await ethers.getContractFactory("Util");
    utilContract = await UtilContract.deploy();

    const Manager = await ethers.getContractFactory("TitanLockerManagerV2", {
      libraries: { Util: utilContract.address },
    });
    manager = await Manager.deploy(feeReceiver.address);

    const ERC20 = await ethers.getContractFactory("TestERC20");
    erc20 = await ERC20.deploy("ERC20", "ERC20", 1000000);
    await erc20.approve(manager.address, ethers.constants.MaxUint256);
  });

  async function newErc20Lock(amount = 1000) {
    const ethFee = await manager.ethFee();
    await manager.createTokenLock(erc20.address, amount, await futureUnlock(), { value: ethFee });
    const id = Number(await manager.tokenLockerCount()) - 1;
    return ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));
  }

  describe("ERC20 lock lifecycle", () => {
    it("Should deposit more and extend the unlock time", async () => {
      const locker = await newErc20Lock(1000);
      await erc20.approve(locker.address, ethers.constants.MaxUint256); // owner approves the child to pull the top-up
      await locker.deposit(500, await futureUnlock(7200));
      const data = await locker.getLockData();
      expect(data.balance).to.equal(1500);
    });

    it("Should reject reducing the unlock time via extendLock", async () => {
      const locker = await newErc20Lock(1000);
      await expect(locker.extendLock(1)).to.be.reverted;
    });

    it("Should reject a non-owner depositing", async () => {
      const locker = await newErc20Lock(1000);
      await expect(locker.connect(other).deposit(1, 0)).to.be.reverted;
    });

    it("Should reject early withdrawal, then allow it after unlock", async () => {
      const locker = await newErc20Lock(1000);
      await expect(locker.withdraw()).to.be.reverted;
      await ethers.provider.send("evm_increaseTime", [3600 * 3]);
      await ethers.provider.send("evm_mine", []);
      const before = await erc20.balanceOf(deployer.address);
      await locker.withdraw();
      expect((await erc20.balanceOf(deployer.address)).sub(before)).to.equal(1000);
    });

    it("Should rescue a stray ERC20 but never the locked token", async () => {
      const locker = await newErc20Lock(1000);
      const Stray = await ethers.getContractFactory("TestERC20");
      const stray = await Stray.deploy("Stray", "STR", 1000);
      await stray.transfer(locker.address, 250);

      await expect(locker.withdrawToken(erc20.address)).to.be.reverted; // locked token
      const before = await stray.balanceOf(deployer.address);
      await locker.withdrawToken(stray.address);
      expect((await stray.balanceOf(deployer.address)).sub(before)).to.equal(250);
    });

    it("Should reject collectFees on an ERC20 lock (wrong kind)", async () => {
      const locker = await newErc20Lock(1000);
      await expect(locker.collectFees()).to.be.reverted;
    });
  });

  describe("stray-NFT rescue", () => {
    let mockV3, strayNfts, locker;

    before(async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      const t0 = await ERC20.deploy("R0", "R0", 1000000);
      const t1 = await ERC20.deploy("R1", "R1", 1000000);

      // the locked position lives on mockV3
      const MockV3 = await ethers.getContractFactory("MockNonfungiblePositionManagerV3");
      mockV3 = await MockV3.deploy();
      await manager.setPositionManager(mockV3.address, KIND.UNIV3, true);
      await mockV3.mint(deployer.address, t0.address, t1.address, 0, 0); // tokenId 0 (will be locked)
      await mockV3.setApprovalForAll(manager.address, true);

      const ethFee = await manager.ethFee();
      await manager.createPositionLock(mockV3.address, 0, await futureUnlock(), { value: ethFee });
      const id = Number(await manager.tokenLockerCount()) - 1;
      locker = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));

      // a DIFFERENT NFT collection, one token of which gets sent to the lock by mistake
      strayNfts = await MockV3.deploy();
      await strayNfts.mint(deployer.address, t0.address, t1.address, 0, 0); // stray tokenId 0
      await strayNfts["safeTransferFrom(address,address,uint256)"](deployer.address, locker.address, 0);
    });

    it("Should rescue a stray NFT to the owner", async () => {
      expect(await strayNfts.ownerOf(0)).to.equal(locker.address);
      await locker.withdrawNft(strayNfts.address, 0);
      expect(await strayNfts.ownerOf(0)).to.equal(deployer.address);
    });

    it("Should refuse to sweep the locked position NFT via withdrawNft", async () => {
      await expect(locker.withdrawNft(mockV3.address, 0)).to.be.reverted;
      // the locked NFT is still held by the lock
      expect(await mockV3.ownerOf(0)).to.equal(locker.address);
    });

    it("Should reject a non-owner rescuing an NFT", async () => {
      await expect(locker.connect(other).withdrawNft(strayNfts.address, 0)).to.be.reverted;
    });
  });

  describe("kind guards on position locks", () => {
    let mockV3, locker;

    before(async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      const t0 = await ERC20.deploy("K0", "K0", 1000000);
      const t1 = await ERC20.deploy("K1", "K1", 1000000);
      const MockV3 = await ethers.getContractFactory("MockNonfungiblePositionManagerV3");
      mockV3 = await MockV3.deploy();
      await manager.setPositionManager(mockV3.address, KIND.UNIV3, true);
      await mockV3.mint(deployer.address, t0.address, t1.address, 0, 0);
      await mockV3.setApprovalForAll(manager.address, true);

      const ethFee = await manager.ethFee();
      await manager.createPositionLock(mockV3.address, 0, await futureUnlock(), { value: ethFee });
      const id = Number(await manager.tokenLockerCount()) - 1;
      locker = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));
    });

    it("Should reject deposit() on a position lock (wrong kind)", async () => {
      await expect(locker.deposit(1, 0)).to.be.reverted;
    });

    it("Should allow extendLock on a position lock", async () => {
      await locker.extendLock(await futureUnlock(7200));
    });
  });

  describe("V4 position lock: ERC20 currencies", () => {
    let mockV4, c0, c1, locker;
    const OWED0 = 800, OWED1 = 1200;

    before(async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      c0 = await ERC20.deploy("C0", "C0", 1000000);
      c1 = await ERC20.deploy("C1", "C1", 1000000);
      const MockV4 = await ethers.getContractFactory("MockPositionManagerV4");
      mockV4 = await MockV4.deploy();
      await manager.setPositionManager(mockV4.address, KIND.UNIV4, true);

      await mockV4.mint(deployer.address, c0.address, c1.address, OWED0, OWED1);
      await c0.transfer(mockV4.address, OWED0);
      await c1.transfer(mockV4.address, OWED1);
      await mockV4.setApprovalForAll(manager.address, true);

      const ethFee = await manager.ethFee();
      await manager.createPositionLock(mockV4.address, 0, await futureUnlock(), { value: ethFee });
      const id = Number(await manager.tokenLockerCount()) - 1;
      locker = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));
    });

    it("Should report kind UNIV4 and hold the NFT", async () => {
      const data = await locker.getLockData();
      expect(data.kind).to.equal(KIND.UNIV4);
      expect(await mockV4.ownerOf(0)).to.equal(locker.address);
    });

    it("Should collect V4 fees to the owner", async () => {
      const b0 = await c0.balanceOf(deployer.address);
      const b1 = await c1.balanceOf(deployer.address);
      await locker.collectFees();
      expect((await c0.balanceOf(deployer.address)).sub(b0)).to.equal(OWED0);
      expect((await c1.balanceOf(deployer.address)).sub(b1)).to.equal(OWED1);
    });

    it("Should return the NFT after unlock", async () => {
      await ethers.provider.send("evm_increaseTime", [3600 * 2]);
      await ethers.provider.send("evm_mine", []);
      await locker.withdraw();
      expect(await mockV4.ownerOf(0)).to.equal(deployer.address);
    });
  });

  describe("V4 position lock: native ETH currency0", () => {
    let mockV4, c1, locker;
    const OWED_ETH = ethers.utils.parseEther("0.03");
    const OWED1 = 1200;

    before(async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      c1 = await ERC20.deploy("E1", "E1", 1000000);
      const MockV4 = await ethers.getContractFactory("MockPositionManagerV4");
      mockV4 = await MockV4.deploy();
      await manager.setPositionManager(mockV4.address, KIND.UNIV4, true);

      // currency0 == address(0) => native ETH
      await mockV4.mint(deployer.address, ZERO, c1.address, OWED_ETH, OWED1);
      await deployer.sendTransaction({ to: mockV4.address, value: OWED_ETH });
      await c1.transfer(mockV4.address, OWED1);
      await mockV4.setApprovalForAll(manager.address, true);

      const ethFee = await manager.ethFee();
      await manager.createPositionLock(mockV4.address, 0, await futureUnlock(), { value: ethFee });
      const id = Number(await manager.tokenLockerCount()) - 1;
      locker = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));
    });

    it("Should pay native-ETH fees out of the position manager to the owner", async () => {
      const mockEthBefore = await ethers.provider.getBalance(mockV4.address);
      const c1Before = await c1.balanceOf(deployer.address);

      await locker.collectFees();

      // ETH left the position manager (went to the owner via TAKE_PAIR)
      expect(mockEthBefore.sub(await ethers.provider.getBalance(mockV4.address))).to.equal(OWED_ETH);
      // and the ERC20 side landed exactly on the owner
      expect((await c1.balanceOf(deployer.address)).sub(c1Before)).to.equal(OWED1);
    });
  });
});
