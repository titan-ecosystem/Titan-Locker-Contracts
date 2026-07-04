module.exports = async ({ deployments, getNamedAccounts }) => {
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const utilLibrary = await get("Util");

  // fee receiver defaults to the deployer; call setFeeReceiver() once a real
  // treasury address exists for this network.
  await deploy("TitanLockerManagerV1", {
    from: deployer,
    args: [deployer],
    log: true,
    libraries: {
      Util: utilLibrary.address,
    },
  });
};

module.exports.tags = ["TitanLocker", "TokenLocker"];
module.exports.dependencies = ["Util"];
