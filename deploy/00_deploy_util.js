module.exports = async ({ deployments, getNamedAccounts }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  await deploy("Util", {
    from: deployer,
    log: true,
  });
};

module.exports.tags = ["TitanLocker", "Util"];
