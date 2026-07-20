module.exports = async ({ deployments, getNamedAccounts }) => {
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const utilLibrary = await get("Util");

  // V2.1: same TitanLockerManagerV2 contract, deployed fresh under its own
  // name so the original TitanLockerManagerV2 deployment record (and its
  // still-live contract) is left untouched. Carries the ContractWolf-audit
  // fixes (5% token-fee cap, caller-supplied max-fee guard, round-up dust
  // fee, zero-amount guard, corrected UNIV4 fee reporting). Fee receiver
  // defaults to the deployer, matching the original V2 deploy's convention.
  await deploy("TitanLockerManagerV2_1", {
    contract: "TitanLockerManagerV2",
    from: deployer,
    args: [deployer],
    log: true,
    libraries: {
      Util: utilLibrary.address,
    },
  });
};

module.exports.tags = ["TitanLockerV2_1"];
module.exports.dependencies = ["Util"];
