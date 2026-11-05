const { expect } = require('chai');
const { ethers } = require('ethers');
const { encodeSignedL2Message } = require('../scripts/elysium-inbox-message');

describe('Elysium signed Inbox message', function () {
  it('prefixes a signed child transaction with Nitro message kind 4', async function () {
    const wallet = new ethers.Wallet('0x' + '11'.repeat(32));
    const raw = await wallet.signTransaction({
      chainId: 99901, type: 2, nonce: 0, to: null, data: '0x60006000f3',
      gasLimit: 100000, maxFeePerGas: 1000000000, maxPriorityFeePerGas: 0,
    });
    const encoded = encodeSignedL2Message(raw);
    expect(encoded.slice(0, 4)).to.equal('0x04');
    expect(encoded.slice(4)).to.equal(raw.slice(2));
    expect(ethers.utils.parseTransaction('0x' + encoded.slice(4)).from).to.equal(wallet.address);
  });
});
