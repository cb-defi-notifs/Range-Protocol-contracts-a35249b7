const hre = require("hardhat");
const {ethers} = require("hardhat");

const TIMELOCK_ABI = require("./TimeLockABI.json");

async function main() {
    const [acc] = await ethers.getSigners();
    const timelockAddress = "0x56D9901451a7a753Ac8251F355951E582691D3a0";
    const factoryAddress = "0x3E89E72026DA6093DD6E4FED767f1f5db2fc0Fb4";

    const Factory = await ethers.getContractFactory("RangeProtocolFactory");
    const timelock = await ethers.getContractAt(TIMELOCK_ABI, timelockAddress);
    const manager = "0x596b79a977f59D8F282B44102964E49Bd171d9E1";
    const tokenA = "0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9";
    const tokenB = "0x5bE26527e817998A7206475496fDE1E68957c5A6";
    const fee = 500;
    const implAddress = "0xDf364639071BD92De439f432aFdF9db2Bbe78A98";
    const name = "Range Agni USDC/USDY 0.05% Pegged LP";
    const symbol = "R-UNI";

    const multisig = "0xb5020eC695b256b0F813547189B523c267737d46";
    await acc.sendTransaction({
        to: multisig,
        value: ethers.utils.parseEther("100"),
    });
    // ethers.provider.accounts = "remote";
    await ethers.provider.send("hardhat_impersonateAccount", [multisig]);

    const sender = await ethers.provider.getSigner(multisig);
    const initData = ethers.utils.defaultAbiCoder.encode(
        ["address", "string", "string"],
        [manager, name, symbol]
    );

    const createVaultData = Factory.interface.encodeFunctionData("createVault", [
        tokenA,
        tokenB,
        fee,
        implAddress,
        initData,
    ]);

    console.log("CREATE PAYLOAD:\n", createVaultData);
    console.log("\n");

    const timelockScheduleData = timelock.interface.encodeFunctionData("schedule", [
        factoryAddress,
        0,
        createVaultData,
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        86400,
    ])
    console.log("TIMELOCK PAYLOAD:\n", timelockScheduleData);

    await timelock.connect(sender).schedule(
        factoryAddress,
        0,
        createVaultData,
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        86400,
    );

    await ethers.provider.send("evm_increaseTime", [864000]);
    await ethers.provider.send("evm_mine");

    const timelockExecuteData = timelock.interface.encodeFunctionData("execute", [
        factoryAddress,
        0,
        createVaultData,
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
    ]);
    const txData = await (
        await timelock.connect(sender).execute(
            factoryAddress,
            0,
            createVaultData,
            "0x0000000000000000000000000000000000000000000000000000000000000000",
            "0x0000000000000000000000000000000000000000000000000000000000000000",
        )
    ).wait();

    txData.logs.forEach(log => {
        try {
            const logParsed = Factory.interface.parseLog(log);
            if (logParsed.name === "VaultCreated") {
                console.log();
                console.log("Pool: ", logParsed.args[0]);
                console.log("Vault: ", logParsed.args[1]);
            }
        } catch (e) {
        }

    });
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
