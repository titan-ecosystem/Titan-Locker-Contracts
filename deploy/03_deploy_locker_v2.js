module.exports = async ({ deployments, getNamedAccounts }) => {
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const utilLibrary = await get("Util");

  // V2 manager: locks plain/LP ERC20 tokens plus Uniswap V3/V4 LP position
  // NFTs, all through one contract. Deployed alongside V1 (V1 stays live);
  // the dapp reads both. Fee receiver defaults to the deployer - call
  // setFeeReceiver() once a real treasury exists. No V3/V4 position manager is
  // usable until it is explicitly allowlisted via scripts/setPositionManagers.js.
  await deploy("TitanLockerManagerV2", {
    from: deployer,
    args: [deployer],
    log: true,
    libraries: {
      Util: utilLibrary.address,
    },
  });
};

module.exports.tags = ["TitanLocker", "TokenLockerV2"];
module.exports.dependencies = ["Util"];
