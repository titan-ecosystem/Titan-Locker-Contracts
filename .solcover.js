module.exports = {
  // Dex.sol: third-party interfaces, not our code. test/: only mocks used to
  // exercise the real contracts, not covered themselves. echidna-tests/:
  // exercised by Echidna directly, not the JS/Mocha suite this report covers.
  skipFiles: [
    'library/Dex.sol',
    'test/TestERC20.sol',
    'test/MockUniswapV2Pair.sol',
    'test/MockNonfungiblePositionManagerV3.sol',
    'test/MockPositionManagerV4.sol',
    'echidna-tests',
  ],
  configureYulOptimizer: true,
  solcOptimizerDetails: {
    yul: true,
  },
}
