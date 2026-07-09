const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

const KIND = { ERC20: 0, UNIV3: 1, UNIV4: 2, ERC20_VESTING: 3 };

async function latestTs() {
  return (await ethers.provider.getBlock("latest")).timestamp;
}
async function setNextTs(t) {
  await ethers.provider.send("evm_setNextBlockTimestamp", [t]);
}
async function mineAt(t) {
  await setNextTs(t);
  await ethers.provider.send("evm_mine", []);
}

describe("TitanLockerV2 vesting", () => {
  let utilContract, manager, token, deployer, feeReceiver, other;

  before(async () => {
    [deployer, feeReceiver, other] = await ethers.getSigners();
    const Util = await ethers.getContractFactory("Util");
    utilContract = await Util.deploy();
    const Manager = await ethers.getContractFactory("TitanLockerManagerV2", {
      libraries: { Util: utilContract.address },
    });
    manager = await Manager.deploy(feeReceiver.address);
    const ERC20 = await ethers.getContractFactory("TestERC20");
    token = await ERC20.deploy("Vest", "VEST", 1000000);
    await token.approve(manager.address, ethers.constants.MaxUint256);
  });

  // create a 100%-ETH-fee-paid vesting lock so the grant equals `amount` exactly
  async function createVesting(amount, start, cliff, end) {
    const ethFee = await manager.ethFee();
    await manager.createVestingLock(token.address, amount, start, cliff, end, { value: ethFee });
    const id = Number(await manager.tokenLockerCount()) - 1;
    return ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));
  }

  async function releaseDelta(locker, signer, atTs) {
    await setNextTs(atTs);
    const before = await token.balanceOf(await signer.getAddress());
    await locker.connect(signer).release();
    return (await token.balanceOf(await signer.getAddress())).sub(before);
  }

  it("Linear (no cliff): releases the exact vested amount over time", async () => {
    const base = (await latestTs()) + 10;
    const start = base + 100, end = base + 1100; // 1000s window, cliff == start
    const locker = await createVesting(10000, start, start, end);

    expect((await locker.getVesting()).total).to.equal(10000);
    expect(await locker.getKind()).to.equal(KIND.ERC20_VESTING);

    expect(await releaseDelta(locker, deployer, start - 10)).to.equal(0);      // before start
    expect(await releaseDelta(locker, deployer, start + 500)).to.equal(5000);  // 50%
    expect(await releaseDelta(locker, deployer, end)).to.equal(5000);          // remaining -> 100%
    expect(await releaseDelta(locker, deployer, end + 100)).to.equal(0);       // fully drained
    expect(await locker.releasedAmount()).to.equal(10000);
  });

  it("With cliff: nothing before the cliff, then the accrued lump, then linear", async () => {
    const base = (await latestTs()) + 10;
    const start = base + 100, cliff = base + 400, end = base + 1100; // cliff at 30% of window
    const locker = await createVesting(10000, start, cliff, end);

    expect(await releaseDelta(locker, deployer, cliff - 10)).to.equal(0);  // after start, before cliff
    expect(await releaseDelta(locker, deployer, cliff)).to.equal(3000);    // at cliff: 300/1000 accrues at once
    expect(await releaseDelta(locker, deployer, end)).to.equal(7000);      // remaining
  });

  it("Reverts the non-vesting exits on a vesting lock", async () => {
    const base = (await latestTs()) + 10;
    const locker = await createVesting(1000, base + 10, base + 10, base + 1000);
    await expect(locker.withdraw()).to.be.reverted;
    await expect(locker.deposit(1, 0)).to.be.reverted;
    await expect(locker.collectFees()).to.be.reverted;
    await expect(locker.extendLock(base + 5000)).to.be.reverted;
  });

  it("Reverts a non-owner releasing, and reverts release on a non-vesting lock", async () => {
    const base = (await latestTs()) + 10;
    const vest = await createVesting(1000, base + 10, base + 10, base + 1000);
    await expect(vest.connect(other).release()).to.be.reverted;

    // a plain ERC20 lock cannot be released
    const ethFee = await manager.ethFee();
    await manager.createTokenLock(token.address, 1000, base + 2000, { value: ethFee });
    const id = Number(await manager.tokenLockerCount()) - 1;
    const plain = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));
    await expect(plain.release()).to.be.reverted;
  });

  it("Rejects an invalid schedule at creation", async () => {
    const base = (await latestTs()) + 10;
    const ethFee = await manager.ethFee();
    // end <= now
    await expect(
      manager.createVestingLock(token.address, 1000, base, base, base - 1, { value: ethFee })
    ).to.be.reverted;
    // start >= end
    await expect(
      manager.createVestingLock(token.address, 1000, base + 1000, base + 1000, base + 1000, { value: ethFee })
    ).to.be.reverted;
    // cliff out of [start, end]
    await expect(
      manager.createVestingLock(token.address, 1000, base + 100, base + 5000, base + 1000, { value: ethFee })
    ).to.be.reverted;
  });

  it("Transferring ownership moves the beneficiary of future releases", async () => {
    const base = (await latestTs()) + 10;
    const start = base + 100, end = base + 1100;
    const locker = await createVesting(10000, start, start, end);

    // deployer claims the first half
    expect(await releaseDelta(locker, deployer, start + 500)).to.equal(5000);

    // hand the vesting to `other`; the rest releases to them
    await locker.transferOwnership(other.address);
    expect(await releaseDelta(locker, other, end)).to.equal(5000);
  });
});
