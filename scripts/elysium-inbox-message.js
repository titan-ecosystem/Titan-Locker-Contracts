const { ethers } = require('ethers');

// Nitro's L2MessageType_signedTx is 4. The delayed Inbox accepts a typed
// L2 message, not bare signed transaction bytes.
function encodeSignedL2Message(rawSignedTransaction) {
  const transaction = ethers.utils.parseTransaction(rawSignedTransaction);
  if (!transaction.from || !transaction.hash) throw new Error('invalid signed child transaction');
  return ethers.utils.solidityPack(['uint8', 'bytes'], [4, rawSignedTransaction]);
}

module.exports = { encodeSignedL2Message };
