const { ethers } = require("hardhat");
const { use, expect } = require("chai");
const { solidity } = require("ethereum-waffle");

use(solidity);

async function futureUnlock(s = 3600) {
  return (await ethers.provider.getBlock("latest")).timestamp + s;
}

// Adversarial: a malicious lock OWNER that re-enters the lock the moment it
// receives an NFT (e.g. while rescuing a stray NFT). Proves the nonReentrant
// guard holds even when the owner is hostile, and that the locked funds cannot
// be pulled out via the reentrant path.
describe("TitanLockerV2 reentrancy (malicious owner via NFT receipt)", () => {
  let manager, token, stray, attacker, locker;
  let deployer, feeReceiver;

  before(async () => {
    [deployer, feeReceiver] = await ethers.getSigners();

    const Util = await ethers.getContractFactory("Util");
    const util = await Util.deploy();
    const Manager = await ethers.getContractFactory("TitanLockerManagerV2", {
      libraries: { Util: util.address },
    });
    manager = await Manager.deploy(feeReceiver.address);

    const ERC20 = await ethers.getContractFactory("TestERC20");
    token = await ERC20.deploy("Tok", "TOK", 1000000);
    await token.approve(manager.address, ethers.constants.MaxUint256);

    // an ordinary ERC20 lock, unlockable shortly
    const ethFee = await manager.ethFee();
    await manager.createTokenLock(token.address, 1000, await futureUnlock(100), 10000, { value: ethFee });
    const id = Number(await manager.tokenLockerCount()) - 1;
    locker = await ethers.getContractAt("TitanLockerV2", await manager.getTokenLockAddress(id));

    // hand the lock to the malicious owner contract
    const Attacker = await ethers.getContractFactory("ReentrantLockOwner");
    attacker = await Attacker.deploy();
    await attacker.setLock(locker.address);
    await locker.transferOwnership(attacker.address);

    // a stray NFT lands in the lock by "mistake"
    const StrayNft = await ethers.getContractFactory("MockNonfungiblePositionManagerV3");
    stray = await StrayNft.deploy();
    await stray.mint(deployer.address, token.address, token.address, 0, 0); // tokenId 0
    await stray["safeTransferFrom(address,address,uint256)"](deployer.address, locker.address, 0);

    // warp past unlock so a reentrant withdraw() would otherwise succeed —
    // isolating the reentrancy guard as the only thing that can block it
    await ethers.provider.send("evm_increaseTime", [200]);
    await ethers.provider.send("evm_mine", []);
  });

  it("Blocks the reentrant withdraw and keeps the locked funds put", async () => {
    await attacker.arm();
    // owner (attacker) rescues the stray NFT; on receipt it re-enters withdraw()
    await attacker.callWithdrawNft(stray.address, 0);

    // the reentrancy was attempted and rejected
    expect(await attacker.reentryTried()).to.equal(true);
    expect(await attacker.reentryReverted()).to.equal(true);

    // the stray NFT was still rescued to the owner
    expect(await stray.ownerOf(0)).to.equal(attacker.address);

    // and the locked 1000 was NOT siphoned out via the reentrant call
    expect(await token.balanceOf(locker.address)).to.equal(1000);
  });

  it("Still allows a normal (non-reentrant) withdraw afterwards", async () => {
    const before = await token.balanceOf(attacker.address);
    await attacker.callWithdraw();
    expect((await token.balanceOf(attacker.address)).sub(before)).to.equal(1000);
    expect(await token.balanceOf(locker.address)).to.equal(0);
  });
});
