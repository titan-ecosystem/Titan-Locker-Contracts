const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

describe("TitanLockerManagerV1.sol", () => {
  let erc20;
  let utilContract;
  let tokenLockerManagerV1Contract;
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
  });

  it("Should deploy TitanLockerManagerV1", async () => {
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

  it("Should reject a zero fee receiver at construction", async () => {
    const TitanLockerManagerV1Contract = await ethers.getContractFactory(
      "TitanLockerManagerV1",
      { libraries: { Util: utilContract.address } }
    );
    await expect(
      TitanLockerManagerV1Contract.deploy(ethers.constants.AddressZero)
    ).to.be.reverted;
  });

  it("Should approve TitanLockerManagerV1 to spend ERC20", async () => {
    await erc20.approve(tokenLockerManagerV1Contract.address, ethers.constants.MaxUint256);
  });

  describe("createTokenLocker(address tokenAddress_,uint256 amount_,uint40 unlockTime_)", () => {
    // 1 hour from now
    const unlockTime = Math.floor(Date.now() / 1000 + 60 * 60);

    it("Should create locker", async () => {
      await tokenLockerManagerV1Contract.createTokenLocker(
        erc20.address,
        1,
        unlockTime
      );
    });

    let lockData;

    it("Should get lockData", async () => {
      lockData = await tokenLockerManagerV1Contract.getTokenLockData(0);

      expect(lockData).to.not.equal(undefined);
    });

    it("Locker should contain the locked token", () => {
      expect(lockData.token).to.equal(erc20.address);
    });

    it("Should contain the correct balance", () => {
      expect(lockData.balance).to.equal(1);
    });

    it("Should index the new lock under the creator's address", async () => {
      const ids = await tokenLockerManagerV1Contract.getTokenLockersForAddress(deployer.address);
      expect(ids.map((id) => Number(id))).to.include(0);
    });

    it("Should deduct the token fee from a larger deposit when paid in-kind", async () => {
      const beforeReceiverBalance = await erc20.balanceOf(feeReceiver.address);

      await tokenLockerManagerV1Contract.createTokenLocker(erc20.address, 10000, unlockTime);

      const id = Number(await tokenLockerManagerV1Contract.tokenLockerCount()) - 1;
      const data = await tokenLockerManagerV1Contract.getTokenLockData(id);

      // default tokenFeeBps is 500 (5%)
      expect(data.balance).to.equal(9500);
      expect((await erc20.balanceOf(feeReceiver.address)).sub(beforeReceiverBalance)).to.equal(500);
    });

    it("Should lock 100% of the deposit when the flat ETH fee is paid instead", async () => {
      const ethFee = await tokenLockerManagerV1Contract.ethFee();
      const beforeReceiverEth = await ethers.provider.getBalance(feeReceiver.address);

      await tokenLockerManagerV1Contract.createTokenLocker(erc20.address, 10000, unlockTime, {
        value: ethFee,
      });

      const id = Number(await tokenLockerManagerV1Contract.tokenLockerCount()) - 1;
      const data = await tokenLockerManagerV1Contract.getTokenLockData(id);

      expect(data.balance).to.equal(10000);
      expect((await ethers.provider.getBalance(feeReceiver.address)).sub(beforeReceiverEth)).to.equal(ethFee);
    });

    it("Should reject an incorrect ETH fee amount", async () => {
      const ethFee = await tokenLockerManagerV1Contract.ethFee();
      await expect(
        tokenLockerManagerV1Contract.createTokenLocker(erc20.address, 10000, unlockTime, {
          value: ethFee.add(1),
        })
      ).to.be.reverted;
    });

    it("Should reject creating a lock while creation is disabled", async () => {
      await tokenLockerManagerV1Contract.setCreationEnabled(false);
      await expect(
        tokenLockerManagerV1Contract.createTokenLocker(erc20.address, 1, unlockTime)
      ).to.be.reverted;
      await tokenLockerManagerV1Contract.setCreationEnabled(true);
    });

    it("Should reject a non-owner disabling creation", async () => {
      await expect(
        tokenLockerManagerV1Contract.connect(other).setCreationEnabled(false)
      ).to.be.reverted;
    });

    describe("fee exemption", () => {
      it("Should let the owner exempt an account from fees", async () => {
        await tokenLockerManagerV1Contract.setFeeExempt(other.address, true);
        expect(await tokenLockerManagerV1Contract.isExemptFromFees(other.address)).to.equal(true);
      });

      it("Should reject a non-owner granting fee exemption", async () => {
        await expect(
          tokenLockerManagerV1Contract.connect(other).setFeeExempt(deployer.address, true)
        ).to.be.reverted;
      });

      it("Should lock 100% of the deposit for an exempt account with no fee taken", async () => {
        await erc20.transfer(other.address, 10000);
        await erc20.connect(other).approve(tokenLockerManagerV1Contract.address, ethers.constants.MaxUint256);

        await tokenLockerManagerV1Contract.connect(other).createTokenLocker(erc20.address, 10000, unlockTime);

        const id = Number(await tokenLockerManagerV1Contract.tokenLockerCount()) - 1;
        const data = await tokenLockerManagerV1Contract.getTokenLockData(id);
        expect(data.balance).to.equal(10000);
      });

      it("Should reject an exempt account sending ETH anyway", async () => {
        await expect(
          tokenLockerManagerV1Contract
            .connect(other)
            .createTokenLocker(erc20.address, 1, unlockTime, { value: 1 })
        ).to.be.reverted;
      });
    });
  });

  describe("fee configuration", () => {
    it("Should return the default fee configuration", async () => {
      expect(await tokenLockerManagerV1Contract.ethFee()).to.equal(ethers.utils.parseEther("0.2"));
      expect(await tokenLockerManagerV1Contract.tokenFeeBps()).to.equal(500);
      expect(await tokenLockerManagerV1Contract.feeReceiver()).to.equal(feeReceiver.address);
    });

    it("Should let the owner update the ETH fee", async () => {
      const newFee = ethers.utils.parseEther("0.5");
      await tokenLockerManagerV1Contract.setEthFee(newFee);
      expect(await tokenLockerManagerV1Contract.ethFee()).to.equal(newFee);
      // restore for later tests
      await tokenLockerManagerV1Contract.setEthFee(ethers.utils.parseEther("0.2"));
    });

    it("Should reject a non-owner updating the ETH fee", async () => {
      await expect(
        tokenLockerManagerV1Contract.connect(other).setEthFee(1)
      ).to.be.reverted;
    });

    it("Should let the owner update the token fee bps", async () => {
      await tokenLockerManagerV1Contract.setTokenFeeBps(1000);
      expect(await tokenLockerManagerV1Contract.tokenFeeBps()).to.equal(1000);
      await tokenLockerManagerV1Contract.setTokenFeeBps(500);
    });

    it("Should reject a token fee bps above 100%", async () => {
      await expect(tokenLockerManagerV1Contract.setTokenFeeBps(10001)).to.be.reverted;
    });

    it("Should let the owner update the fee receiver", async () => {
      await tokenLockerManagerV1Contract.setFeeReceiver(other.address);
      expect(await tokenLockerManagerV1Contract.feeReceiver()).to.equal(other.address);
      await tokenLockerManagerV1Contract.setFeeReceiver(feeReceiver.address);
    });

    it("Should reject setting a zero-address fee receiver", async () => {
      await expect(
        tokenLockerManagerV1Contract.setFeeReceiver(ethers.constants.AddressZero)
      ).to.be.reverted;
    });
  });

  describe("notifyLockerOwnerChange(uint40,address,address,address)", () => {
    it("Should reject being called by anything other than a real locker contract", async () => {
      await expect(
        tokenLockerManagerV1Contract.notifyLockerOwnerChange(0, other.address, deployer.address, deployer.address)
      ).to.be.reverted;
    });
  });

  describe("creating a locker for an LP token", () => {
    it("Should index the lock under both underlying tokens", async () => {
      const ERC20 = await ethers.getContractFactory("TestERC20");
      const tokenA = await ERC20.deploy("Token A", "TOKA", 1000000);
      const tokenB = await ERC20.deploy("Token B", "TOKB", 1000000);

      const MockPair = await ethers.getContractFactory("MockUniswapV2Pair");
      const lpToken = await MockPair.deploy(tokenA.address, tokenB.address, 111, 222, 1000000);

      await tokenA.transfer(lpToken.address, 5000);
      await tokenB.transfer(lpToken.address, 7000);

      await lpToken.approve(tokenLockerManagerV1Contract.address, ethers.constants.MaxUint256);
      await tokenLockerManagerV1Contract.createTokenLocker(
        lpToken.address,
        1,
        Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 365
      );

      const id = Number(await tokenLockerManagerV1Contract.tokenLockerCount()) - 1;

      const idsForTokenA = await tokenLockerManagerV1Contract.getTokenLockersForAddress(tokenA.address);
      const idsForTokenB = await tokenLockerManagerV1Contract.getTokenLockersForAddress(tokenB.address);
      expect(idsForTokenA.map((x) => Number(x))).to.include(id);
      expect(idsForTokenB.map((x) => Number(x))).to.include(id);

      const lpData = await tokenLockerManagerV1Contract.getLpData(id);
      expect(lpData.hasLpData).to.equal(true);
      expect(lpData.token0).to.equal(tokenA.address);
      expect(lpData.token1).to.equal(tokenB.address);
    });
  });
});
