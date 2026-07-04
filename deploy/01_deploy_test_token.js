// Convenience ERC20 for local testing only - lets `yarn chain` + `yarn deploy`
// give you something to lock immediately on localhost/hardhat networks.
module.exports = async ({ deployments, getNamedAccounts, network }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  await deploy("TestERC20", {
    from: deployer,
    args: ["Titan Test Token", "TTT", 1000000],
    log: true,
  });
};

module.exports.tags = ["TitanLocker", "TestToken"];
module.exports.skip = async ({ network }) =>
  !["localhost", "hardhat"].includes(network.name);
