import { HardhatUserConfig } from "hardhat/config";

// PLUGINS
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-deploy";
import "solidity-coverage";
import "@nomicfoundation/hardhat-chai-matchers";
import "hardhat-gas-reporter";
import "hardhat-contract-sizer";

// Process Env Variables
import * as dotenv from "dotenv";
dotenv.config({ path: __dirname + "/.env" });
const ALCHEMY_ID = process.env.ALCHEMY_ID;
const PK = process.env.PK;
const PK_TEST = process.env.PK_TEST;

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true
    },
    mainnet: {
      accounts: PK ? [PK] : [],
      chainId: 1,
      url: `https://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_ID}`,
    },
    polygon: {
      accounts: PK ? [PK] : [],
      chainId: 137,
      url: `https://polygon-mainnet.g.alchemy.com/v2/${ALCHEMY_ID}`,
    },
    optimism: {
      accounts: PK ? [PK] : [],
      chainId: 10,
      url: `https://opt-mainnet.g.alchemy.com/v2/${ALCHEMY_ID}`,
    },
    arbitrum: {
      accounts: PK ? [PK] : [],
      chainId: 42161,
      url: `https://arb-mainnet.g.alchemy.com/v2/${ALCHEMY_ID}`,
    },
    goerli: {
      accounts: PK_TEST ? [PK_TEST] : [],
      chainId: 5,
      url: `https://eth-goerli.alchemyapi.io/v2/${ALCHEMY_ID}`,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      accounts: [

          // "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
      ],
    },
  },

  solidity: {
    compilers: [
      {
        version: "0.7.3",
        settings: {
          optimizer: { enabled: true, runs: 100 },
        },
      },
      {
        version: "0.8.4",
        settings: {
          optimizer: { enabled: true, runs: 100 },
        },
      },
    ],
  },
  external: {
    contracts: [
      {
        artifacts: "node_modules/@uniswap/v3-core/artifacts",
      },
      {
        artifacts: "node_modules/@uniswap/v3-periphery/artifacts",
      },
    ],
  },
  typechain: {
    outDir: "typechain",
    target: "ethers-v5",
  },
};

export default config;
