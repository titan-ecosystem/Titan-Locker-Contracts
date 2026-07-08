const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

// LockKind enum
const KIND = { ERC20: 0, UNIV3: 1, UNIV4: 2 };

async function futureUnlock(secondsFromNow = 3600) {
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  return now + secondsFromNow;
}

describe("TitanLockerManagerV2.sol", () => {
  let erc20, utilContract, manager;
  let deployer, feeReceiver, other;

  before(async () => {
    [deployer, feeReceiver, other] = await ethers.getSigners();

    const UtilContract = await ethers.getContractFactory("Util");
    utilContract = await UtilContract.deploy();

    const ERC20 = await ethers.getContractFactory("TestERC20");
    erc20 = await ERC20.deploy("ERC20", "ERC20", 1000000);

    const Manager = await ethers.getContractFactory("TitanLockerManagerV2", {
      libraries: { Util: utilContract.address },
    });
    manager = await Manager.deploy(feeReceiver.address);

    await erc20.approve(manager.address, ethers.constants.MaxUint256);
  });

  it("Should reject a zero fee receiver at construction", async () => {
    const Manager = await ethers.getContractFactory("TitanLockerManagerV2", {
      libraries: { Util: utilContract.address },
    });
    await expect(Manager.deploy(ethers.constants.AddressZero)).to.be.reverted;
  });

  describe("ERC20 lock path (parity with V1)", () => {
    it("Should create a token lock and report kind ERC20", async () => {
      const unlockTime = await futureUnlock();
      await manager.createTokenLock(erc20.address, 1, unlockTime);

      const data = await manager.getTokenLockData(0);
      expect(data.kind).to.equal(KIND.ERC20);
      expect(data.asset).to.equal(erc20.address);
      expect(data.tokenId).to.equal(0);
      expect(data.balance).to.equal(1);
    });

    it("Should deduct the in-kind token fee from a larger deposit", async () => {
      const unlockTime = await futureUnlock();
      const beforeReceiver = await erc20.balanceOf(feeReceiver.address);
      await manager.createTokenLock(erc20.address, 10000, unlockTime);

      const id = Number(await manager.tokenLockerCount()) - 1;
      const data = await manager.getTokenLockData(id);
      expect(data.balance).to.equal(9500); // default 5%
      expect((await erc20.balanceOf(feeReceiver.address)).sub(beforeReceiver)).to.equal(500);
    });

    it("Should lock 100% when the flat ETH fee is paid", async () => {
      const unlockTime = await futureUnlock();
      const ethFee = await manager.ethFee();
      await manager.createTokenLock(erc20.address, 10000, unlockTime, { value: ethFee });
      const id = Number(await manager.tokenLockerCount()) - 1;
      expect((await manager.getTokenLockData(id)).balance).to.equal(10000);
    });

    it("Should index an LP-token lock under both underlying tokens", async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      const tokenA = await ERC20.deploy("Token A", "TOKA", 1000000);
      const tokenB = await ERC20.deploy("Token B", "TOKB", 1000000);
      const MockPair = await ethers.getContractFactory("MockUniswapV2Pair");
      const lpToken = await MockPair.deploy(tokenA.address, tokenB.address, 111, 222, 1000000);
      await tokenA.transfer(lpToken.address, 5000);
      await tokenB.transfer(lpToken.address, 7000);
      await lpToken.approve(manager.address, ethers.constants.MaxUint256);

      await manager.createTokenLock(lpToken.address, 1, await futureUnlock());
      const id = Number(await manager.tokenLockerCount()) - 1;

      const idsA = await manager.getTokenLockersForAddress(tokenA.address);
      const idsB = await manager.getTokenLockersForAddress(tokenB.address);
      expect(idsA.map(Number)).to.include(id);
      expect(idsB.map(Number)).to.include(id);
    });
  });

  describe("position-manager allowlist", () => {
    let mockV3;

    before(async () => {
      const MockV3 = await ethers.getContractFactory("MockNonfungiblePositionManagerV3");
      mockV3 = await MockV3.deploy();
    });

    it("Should default to not-allowed / kind ERC20", async () => {
      const res = await manager.positionManagerKind(mockV3.address);
      expect(res.allowed).to.equal(false);
    });

    it("Should reject allowlisting with the ERC20 kind", async () => {
      await expect(manager.setPositionManager(mockV3.address, KIND.ERC20, true)).to.be.reverted;
    });

    it("Should let the owner allowlist a V3 position manager", async () => {
      await manager.setPositionManager(mockV3.address, KIND.UNIV3, true);
      const res = await manager.positionManagerKind(mockV3.address);
      expect(res.kind).to.equal(KIND.UNIV3);
      expect(res.allowed).to.equal(true);
    });

    it("Should reject a non-owner allowlisting", async () => {
      await expect(
        manager.connect(other).setPositionManager(mockV3.address, KIND.UNIV3, true)
      ).to.be.reverted;
    });

    it("Should reject a position lock against a non-allowlisted manager", async () => {
      const MockV3 = await ethers.getContractFactory("MockNonfungiblePositionManagerV3");
      const rogue = await MockV3.deploy();
      const ethFee = await manager.ethFee();
      await expect(
        manager.createPositionLock(rogue.address, 0, await futureUnlock(), { value: ethFee })
      ).to.be.reverted;
    });
  });

  describe("V3 position lock: create -> collectFees -> withdraw", () => {
    let mockV3, token0, token1, lockerAddr, id;
    const OWED0 = 1000, OWED1 = 2000;

    before(async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      token0 = await ERC20.deploy("T0", "T0", 1000000);
      token1 = await ERC20.deploy("T1", "T1", 1000000);

      const MockV3 = await ethers.getContractFactory("MockNonfungiblePositionManagerV3");
      mockV3 = await MockV3.deploy();
      await manager.setPositionManager(mockV3.address, KIND.UNIV3, true);

      await mockV3.mint(deployer.address, token0.address, token1.address, OWED0, OWED1); // tokenId 0
      // fund the mock so it can pay out fees
      await token0.transfer(mockV3.address, OWED0);
      await token1.transfer(mockV3.address, OWED1);

      await mockV3.setApprovalForAll(manager.address, true);
    });

    it("Should create the V3 lock and take custody of the NFT", async () => {
      const ethFee = await manager.ethFee();
      await manager.createPositionLock(mockV3.address, 0, await futureUnlock(), { value: ethFee });
      id = Number(await manager.tokenLockerCount()) - 1;

      const data = await manager.getTokenLockData(id);
      expect(data.kind).to.equal(KIND.UNIV3);
      expect(data.asset).to.equal(mockV3.address);
      expect(data.tokenId).to.equal(0);

      lockerAddr = await manager.getTokenLockAddress(id);
      expect(await mockV3.ownerOf(0)).to.equal(lockerAddr);
    });

    it("Should index the V3 lock under both underlying tokens", async () => {
      const idsA = await manager.getTokenLockersForAddress(token0.address);
      const idsB = await manager.getTokenLockersForAddress(token1.address);
      expect(idsA.map(Number)).to.include(id);
      expect(idsB.map(Number)).to.include(id);
    });

    it("Should require the flat ETH fee (reject wrong amount)", async () => {
      await mockV3.mint(deployer.address, token0.address, token1.address, 0, 0); // tokenId 1
      await expect(
        manager.createPositionLock(mockV3.address, 1, await futureUnlock(), { value: 0 })
      ).to.be.reverted;
    });

    it("Should let the lock owner collect fees straight to themselves", async () => {
      const locker = await ethers.getContractAt("TitanLockerV2", lockerAddr);
      const before0 = await token0.balanceOf(deployer.address);
      const before1 = await token1.balanceOf(deployer.address);

      await locker.collectFees();

      expect((await token0.balanceOf(deployer.address)).sub(before0)).to.equal(OWED0);
      expect((await token1.balanceOf(deployer.address)).sub(before1)).to.equal(OWED1);
    });

    it("Should reject a non-owner collecting fees", async () => {
      const locker = await ethers.getContractAt("TitanLockerV2", lockerAddr);
      await expect(locker.connect(other).collectFees()).to.be.reverted;
    });

    it("Should reject withdrawing the NFT before unlock, then allow it after", async () => {
      const locker = await ethers.getContractAt("TitanLockerV2", lockerAddr);
      await expect(locker.withdraw()).to.be.reverted;

      await ethers.provider.send("evm_increaseTime", [3600 * 2]);
      await ethers.provider.send("evm_mine", []);

      await locker.withdraw();
      expect(await mockV3.ownerOf(0)).to.equal(deployer.address);
    });
  });

  describe("fee-claim isolation (anti-rug)", () => {
    let mockV3, token0, token1, lockerA, lockerB;
    const A0 = 1000, A1 = 1000, B0 = 500, B1 = 500;

    before(async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      token0 = await ERC20.deploy("I0", "I0", 1000000);
      token1 = await ERC20.deploy("I1", "I1", 1000000);

      const MockV3 = await ethers.getContractFactory("MockNonfungiblePositionManagerV3");
      mockV3 = await MockV3.deploy();
      await manager.setPositionManager(mockV3.address, KIND.UNIV3, true);

      // lock A owned by deployer
      await mockV3.mint(deployer.address, token0.address, token1.address, A0, A1); // id token 0
      // lock B owned by `other`
      await mockV3.mint(other.address, token0.address, token1.address, B0, B1); // id token 1

      await token0.transfer(mockV3.address, A0 + B0);
      await token1.transfer(mockV3.address, A1 + B1);

      const ethFee = await manager.ethFee();
      await mockV3.setApprovalForAll(manager.address, true);
      await manager.createPositionLock(mockV3.address, 0, await futureUnlock(), { value: ethFee });
      const idA = Number(await manager.tokenLockerCount()) - 1;
      lockerA = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(idA));

      await mockV3.connect(other).setApprovalForAll(manager.address, true);
      await manager.connect(other).createPositionLock(mockV3.address, 1, await futureUnlock(), { value: ethFee });
      const idB = Number(await manager.tokenLockerCount()) - 1;
      lockerB = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(idB));
    });

    it("Should not let owner B's fee claim touch lock A's fees", async () => {
      // B claims: gets exactly B's fees
      const beforeOther0 = await token0.balanceOf(other.address);
      await lockerB.connect(other).collectFees();
      expect((await token0.balanceOf(other.address)).sub(beforeOther0)).to.equal(B0);

      // A's fees remain fully intact and claimable by A
      const beforeDep0 = await token0.balanceOf(deployer.address);
      await lockerA.collectFees();
      expect((await token0.balanceOf(deployer.address)).sub(beforeDep0)).to.equal(A0);
    });

    it("Should forbid owner B from collecting on lock A entirely", async () => {
      await expect(lockerA.connect(other).collectFees()).to.be.reverted;
    });
  });
});
