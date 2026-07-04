const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

describe("TitanLockerV1.sol", () => {
  let erc20;
  let strayToken;
  let utilContract;
  let tokenLockerManagerV1Contract;
  let tokenLockerV1Contract;
  let TitanLockerV1Contract;
  let deployer, feeReceiver, other;

  before(async () => {
    [deployer, feeReceiver, other] = await ethers.getSigners();
  });

  before(async () => {
    const UtilContract = await ethers.getContractFactory("Util");
    utilContract = await UtilContract.deploy();
  });

  before(async () => {
    const ERC20 = await ethers.getContractFactory("TestERC20");
    erc20 = await ERC20.deploy("ERC20", "ERC20", 1000000);
    strayToken = await ERC20.deploy("Stray", "STRAY", 1000000);
  });

  before(async () => {
    const TitanLockerManagerV1Contract = await ethers.getContractFactory(
      "TitanLockerManagerV1",
      {
        libraries: {
          Util: utilContract.address,
        },
      }
    );
    tokenLockerManagerV1Contract = await TitanLockerManagerV1Contract.deploy(
      feeReceiver.address
    );
  });

  before(async () => {
    TitanLockerV1Contract = await ethers.getContractFactory("TitanLockerV1", {
      libraries: { Util: utilContract.address },
    });
  });

  it("Should reject an unlock time that isn't in the future", async () => {
    await expect(
      TitanLockerV1Contract.deploy(
        tokenLockerManagerV1Contract.address,
        1,
        deployer.address,
        erc20.address,
        Math.floor(Date.now() / 1000) - 1
      )
    ).to.be.reverted;
  });

  it("Should reject a zero-address owner", async () => {
    await expect(
      TitanLockerV1Contract.deploy(
        tokenLockerManagerV1Contract.address,
        1,
        ethers.constants.AddressZero,
        erc20.address,
        Math.floor(Date.now() / 1000 + 60 * 60)
      )
    ).to.be.reverted;
  });

  let unlockTime;

  it("Should deploy TitanLockerV1", async () => {
    // Hardhat Network's block timestamps march forward at least 1 second
    // per mined block regardless of real elapsed time, so a lot of prior
    // transactions in this run can leave the chain's clock well ahead of
    // Date.now() - use the actual latest block's timestamp as the baseline
    // instead of wall-clock time, plus a comfortable buffer.
    const latestBlock = await ethers.provider.getBlock("latest");
    unlockTime = latestBlock.timestamp + 60 * 60;

    // constructor(address manager_, uint40 id_, address owner_, address tokenAddress_, uint40 unlockTime_)
    tokenLockerV1Contract = await TitanLockerV1Contract.deploy(
      tokenLockerManagerV1Contract.address,
      1,
      deployer.address,
      erc20.address,
      unlockTime
    );
  });

  it("Should transfer tokens to locker", async () => {
    await erc20.transfer(tokenLockerV1Contract.address, 1);

    // verify
    expect(await erc20.balanceOf(tokenLockerV1Contract.address)).to.equal(1);
  });

  it("Should reject withdrawing from the wrong account", async () => {
    await expect(tokenLockerV1Contract.connect(other).withdraw()).to.be.reverted;
  });

  it("Should revert on early withdrawal", async () => {
    // reverts with the custom error LockStillActive(uint40), not a string reason
    await expect(tokenLockerV1Contract.withdraw()).to.be.reverted;
  });

  it("Should allow withdrawal after unlockTime", async () => {
    // fast-forward the chain past unlockTime instead of sleeping in real time
    await ethers.provider.send("evm_increaseTime", [60 * 60 + 1]);
    await ethers.provider.send("evm_mine");

    await tokenLockerV1Contract.withdraw();

    // balance should now be 0
    expect(await erc20.balanceOf(tokenLockerV1Contract.address)).to.equal(0);
  });

  it("Should deposit and extend lock duration", async () => {
    const latestBlock = await ethers.provider.getBlock("latest");
    const newUnlockTime = latestBlock.timestamp + 60 * 60;

    await erc20.approve(tokenLockerV1Contract.address, 1);
    await tokenLockerV1Contract.deposit(1, newUnlockTime);

    const { balance, unlockTime } = await tokenLockerV1Contract.getLockData();

    expect(balance).to.equal(1);
    expect(unlockTime).to.equal(newUnlockTime);
  });

  it("Should reject reducing the unlock time via deposit", async () => {
    const { unlockTime } = await tokenLockerV1Contract.getLockData();
    await expect(tokenLockerV1Contract.deposit(0, unlockTime - 1)).to.be.reverted;
  });

  describe("rescuing stray assets", () => {
    it("Should reject sweeping the locked token itself via withdrawToken", async () => {
      await expect(tokenLockerV1Contract.withdrawToken(erc20.address)).to.be.reverted;
    });

    it("Should sweep a stray ERC20 token to the owner", async () => {
      await strayToken.transfer(tokenLockerV1Contract.address, 500);
      const before = await strayToken.balanceOf(deployer.address);

      await tokenLockerV1Contract.withdrawToken(strayToken.address);

      expect(await strayToken.balanceOf(tokenLockerV1Contract.address)).to.equal(0);
      expect((await strayToken.balanceOf(deployer.address)).sub(before)).to.equal(500);
    });

    it("Should reject a non-owner sweeping a stray token", async () => {
      await strayToken.transfer(tokenLockerV1Contract.address, 1);
      await expect(
        tokenLockerV1Contract.connect(other).withdrawToken(strayToken.address)
      ).to.be.reverted;
      await tokenLockerV1Contract.withdrawToken(strayToken.address);
    });

    it("Should sweep stray ETH to the owner", async () => {
      await deployer.sendTransaction({ to: tokenLockerV1Contract.address, value: 1000 });
      const before = await ethers.provider.getBalance(deployer.address);

      const tx = await tokenLockerV1Contract.withdrawEth();
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed.mul(receipt.effectiveGasPrice || tx.gasPrice);

      expect(await ethers.provider.getBalance(tokenLockerV1Contract.address)).to.equal(0);
      expect((await ethers.provider.getBalance(deployer.address)).add(gasCost).sub(before)).to.equal(1000);
    });

    it("Should reject a non-owner sweeping ETH", async () => {
      await deployer.sendTransaction({ to: tokenLockerV1Contract.address, value: 1000 });
      await expect(tokenLockerV1Contract.connect(other).withdrawEth()).to.be.reverted;
    });
  });

  describe("ownership transfer (via a manager-created lock)", () => {
    let managedLockId;
    let managedLockAddress;

    it("Should create a lock through the manager", async () => {
      await erc20.approve(tokenLockerManagerV1Contract.address, ethers.constants.MaxUint256);
      await tokenLockerManagerV1Contract.setFeeExempt(deployer.address, true);

      const latestBlock = await ethers.provider.getBlock("latest");
      await tokenLockerManagerV1Contract.createTokenLocker(
        erc20.address,
        1,
        latestBlock.timestamp + 60 * 60
      );

      managedLockId = Number(await tokenLockerManagerV1Contract.tokenLockerCount()) - 1;
      managedLockAddress = await tokenLockerManagerV1Contract.getTokenLockAddress(managedLockId);
    });

    it("Should transfer ownership and update the manager's search index", async () => {
      const managedLock = TitanLockerV1Contract.attach(managedLockAddress);
      await managedLock.transferOwnership(other.address);

      expect(await managedLock.owner()).to.equal(other.address);

      const idsForNewOwner = await tokenLockerManagerV1Contract.getTokenLockersForAddress(other.address);
      expect(idsForNewOwner.map((id) => Number(id))).to.include(managedLockId);
    });
  });

  describe("locking an LP token", () => {
    let lpToken;
    let lpLocker;

    it("Should deploy a lock for a mock LP token and detect it as an LP token", async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      const tokenA = await ERC20.deploy("Token A", "TOKA", 1000000);
      const tokenB = await ERC20.deploy("Token B", "TOKB", 1000000);

      const MockPair = await ethers.getContractFactory("MockUniswapV2Pair");
      lpToken = await MockPair.deploy(tokenA.address, tokenB.address, 111, 222, 1000000);

      await tokenA.transfer(lpToken.address, 5000);
      await tokenB.transfer(lpToken.address, 7000);

      const latestBlock = await ethers.provider.getBlock("latest");
      lpLocker = await TitanLockerV1Contract.deploy(
        tokenLockerManagerV1Contract.address,
        999,
        deployer.address,
        lpToken.address,
        latestBlock.timestamp + 60 * 60
      );

      expect(await lpLocker.getIsLpToken()).to.equal(true);
    });

    it("Should return real LP data once tokens are locked", async () => {
      await lpToken.approve(lpLocker.address, 1);
      await lpLocker.deposit(1, 0);

      const lpData = await lpLocker.getLpData();

      expect(lpData.hasLpData).to.equal(true);
      expect(lpData.token0).to.equal((await lpToken.token0()));
      expect(lpData.token1).to.equal((await lpToken.token1()));
      expect(lpData.balance0).to.equal(5000);
      expect(lpData.balance1).to.equal(7000);
      expect(lpData.price0).to.equal(111);
      expect(lpData.price1).to.equal(222);
    });
  });
});
