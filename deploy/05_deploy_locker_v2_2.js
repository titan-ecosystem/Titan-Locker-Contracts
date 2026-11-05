module.exports = async ({ deployments, getNamedAccounts, getChainId }) => {
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainId = Number(await getChainId());
  if (chainId !== 31337 && chainId !== 4663) throw new Error("V2.2 direct deploy is Robinhood-only");
  if (chainId === 4663 && process.env.TITAN_V22_DEPLOY !== "YES") {
    throw new Error("set TITAN_V22_DEPLOY=YES for an approved Robinhood release");
  }
  const utilLibrary = await get("Util");

  // New deployment record: V2 and V2.1 remain immutable at their existing
  // addresses. Run only as part of an explicitly approved release.
  await deploy("TitanLockerManagerV2_2", {
    contract: "TitanLockerManagerV2",
    from: deployer,
    args: [deployer],
    log: true,
    libraries: { Util: utilLibrary.address },
  });
};

module.exports.tags = ["TitanLockerV2_2"];
module.exports.dependencies = ["Util"];
