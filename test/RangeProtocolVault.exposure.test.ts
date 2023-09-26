import { ethers } from "hardhat";
import { expect } from "chai";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import {
  IERC20,
  IAlgebraFactory,
  IAlgebraPool,
  RangeProtocolVault,
  RangeProtocolFactory,
  SwapTest,
} from "../typechain";
import { bn, encodePriceSqrt, getInitializeData, parseEther } from "./common";
import { beforeEach } from "mocha";
import { BigNumber } from "ethers";

let factory: RangeProtocolFactory;
let vaultImpl: RangeProtocolVault;
let vault: RangeProtocolVault;
let algebraFactory: IAlgebraFactory;
let algebraPool: IAlgebraPool;
let nonfungiblePositionManager: string;
let nonfungiblePositionManagerMintInterface;
let token0: IERC20;
let token1: IERC20;
let manager: SignerWithAddress;
let trader: SignerWithAddress;
let nonManager: SignerWithAddress;
let newManager: SignerWithAddress;
let user2: SignerWithAddress;
let lpProvider: SignerWithAddress;
const poolFee = 3000;
const name = "Test Token";
const symbol = "TT";
const amount0: BigNumber = parseEther("2");
const amount1: BigNumber = parseEther("3");
let initializeData: any;
const bottomTick = -887220;
const topTick = 887220;

describe("RangeProtocolVault::exposure", () => {
  before(async () => {
    [manager, nonManager, user2, newManager, trader, lpProvider] =
      await ethers.getSigners();
    algebraFactory = (await ethers.getContractAt(
      "IAlgebraFactory",
      "0x1a3c9B1d2F0529D97f2afC5136Cc23e58f1FD35B"
    )) as IAlgebraFactory;

    nonfungiblePositionManager = "0x00c7f3082833e796A5b3e4Bd59f6642FF44DCD15";
    nonfungiblePositionManagerMintInterface = new ethers.utils.Interface([
      "function mint(tuple(address,address,int24,int24,uint256,uint256,uint256,uint256,address,uint256)) external payable returns (uint256,uint128,uint256,uint256)",
    ]);
    const RangeProtocolFactory = await ethers.getContractFactory(
      "RangeProtocolFactory"
    );
    factory = (await RangeProtocolFactory.deploy(
      algebraFactory.address
    )) as RangeProtocolFactory;

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token0 = (await MockERC20.deploy()) as IERC20;
    token1 = (await MockERC20.deploy()) as IERC20;

    if (bn(token0.address).gt(token1.address)) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await algebraFactory.createPool(token0.address, token1.address);
    algebraPool = (await ethers.getContractAt(
      "IAlgebraPool",
      await algebraFactory.poolByPair(token0.address, token1.address)
    )) as IAlgebraPool;

    await algebraPool.initialize(encodePriceSqrt("1", "1"));
    initializeData = getInitializeData({
      managerAddress: manager.address,
      name,
      symbol,
    });

    // eslint-disable-next-line @typescript-eslint/naming-convention
    const RangeProtocolVault = await ethers.getContractFactory(
      "RangeProtocolVault"
    );
    vaultImpl = (await RangeProtocolVault.deploy()) as RangeProtocolVault;

    await factory.createVault(
      token0.address,
      token1.address,
      vaultImpl.address,
      initializeData
    );

    const vaultAddress = await factory.getVaultAddresses(0, 0);
    vault = (await ethers.getContractAt(
      "RangeProtocolVault",
      vaultAddress[0]
    )) as RangeProtocolVault;

    await expect(vault.connect(manager).updateTicks(bottomTick, topTick));
  });

  beforeEach(async () => {
    await token0.approve(vault.address, amount0.mul(bn(2)));
    await token1.approve(vault.address, amount1.mul(bn(2)));
  });

  it("should mint with zero totalSupply of vault shares", async () => {
    await token0.connect(lpProvider).mint();
    await token1.connect(lpProvider).mint();

    const {
      mintAmount: mintAmountLpProvider,
      amount0: amount0LpProvider,
      amount1: amount1LpProvider,
    } = await vault.getMintAmounts(amount0.mul(10), amount1.mul(10));

    await token0
      .connect(lpProvider)
      .approve(nonfungiblePositionManager, amount0LpProvider);
    await token1
      .connect(lpProvider)
      .approve(nonfungiblePositionManager, amount1LpProvider);

    await ethers.provider.send("eth_sendTransaction", [
      {
        from: lpProvider.address,
        to: nonfungiblePositionManager,
        data: nonfungiblePositionManagerMintInterface.encodeFunctionData(
          "mint",
          [
            [
              token0.address,
              token1.address,
              bottomTick,
              topTick,
              amount0LpProvider,
              amount1LpProvider,
              0,
              0,
              lpProvider.address,
              new Date().getTime() + 10000000,
            ],
          ]
        ),
      },
    ]);

    const {
      mintAmount: mintAmount1,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amount0: amount0Mint1,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amount1: amount1Mint1,
    } = await vault.getMintAmounts(amount0, amount1);

    await expect(vault.mint(mintAmount1))
      .to.emit(vault, "Minted")
      .withArgs(manager.address, mintAmount1, amount0Mint1, amount1Mint1);

    console.log("Users 1:");
    console.log("mint amount: ", mintAmount1.toString());
    console.log("token0 amount: ", amount0Mint1.toString());
    console.log("token1 amount: ", amount1Mint1.toString());
    console.log("==================================================");

    await token0.connect(newManager).mint();
    await token1.connect(newManager).mint();

    const {
      mintAmount: mintAmount2,
      amount0: amount0Mint2,
      amount1: amount1Mint2,
    } = await vault.getMintAmounts(amount0, amount1);
    await token0.connect(newManager).approve(vault.address, amount0Mint2);
    await token1.connect(newManager).approve(vault.address, amount1Mint2);

    await vault.connect(newManager).mint(mintAmount2);

    console.log("Users 2:");
    console.log("mint amount: ", mintAmount1.toString());
    console.log("token0 amount: ", amount0Mint2.toString());
    console.log("token1 amount: ", amount1Mint2.toString());
    console.log("==================================================");

    const SwapTest = await ethers.getContractFactory("SwapTest");
    const swapTest = (await SwapTest.deploy()) as SwapTest;

    const { amount0Current: amount0Current1, amount1Current: amount1Current1 } =
      await vault.getUnderlyingBalances();
    console.log("Vault balance: ");
    console.log("token0 amount: ", amount0Current1.toString());
    console.log("token1 amount: ", amount1Current1.toString());
    console.log("==================================================");

    console.log(
      "perform external swap " + amount1.toString(),
      " of token1 to token0 to move price"
    );
    console.log("==================================================");

    await token0.connect(trader).mint();
    await token1.connect(trader).mint();

    await token0.connect(trader).approve(swapTest.address, amount0);
    await token1.connect(trader).approve(swapTest.address, amount1);

    await swapTest.connect(trader).swapZeroForOne(algebraPool.address, amount1);

    const { amount0Current: amount0Current2, amount1Current: amount1Current2 } =
      await vault.getUnderlyingBalances();
    console.log("Vault balance after swap: ");
    console.log("token0 amount: ", amount0Current2.toString());
    console.log("token1 amount: ", amount1Current2.toString());
    console.log("==================================================");

    console.log("User2 mints for the second time (after price movement)");
    await token0.connect(newManager).mint();
    await token1.connect(newManager).mint();

    const {
      mintAmount: mintAmount3,
      amount0: amount0Mint3,
      amount1: amount1Mint3,
    } = await vault.getMintAmounts(amount0, amount1);
    await token0.connect(newManager).approve(vault.address, amount0Mint3);
    await token1.connect(newManager).approve(vault.address, amount1Mint3);
    console.log("Users 2:");
    console.log(
      "vault shares before: ",
      (await vault.balanceOf(newManager.address)).toString()
    );

    await vault.connect(newManager).mint(mintAmount3);
    console.log(
      "vault shares after: ",
      (await vault.balanceOf(newManager.address)).toString()
    );

    console.log("==================================================");

    console.log("Vault balance after user2 mints for the second time: ");

    const { amount0Current: amount0Current3, amount1Current: amount1Current3 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amount0Current3.toString());
    console.log("token1 amount: ", amount1Current3.toString());
    console.log("==================================================");

    console.log("Remove liquidity from algebra pool");
    await vault.removeLiquidity();
    console.log("==================================================");

    console.log("Total users vault amounts based on their initial deposits");
    const userVaults = await vault.getUserVaults(0, 0);
    const { token0VaultTotal, token1VaultTotal } = userVaults.reduce(
      (acc, { token0, token1 }) => {
        return {
          token0VaultTotal: acc.token0VaultTotal.add(token0),
          token1VaultTotal: acc.token1VaultTotal.add(token1),
        };
      },
      {
        token0VaultTotal: bn(0),
        token1VaultTotal: bn(0),
      }
    );
    console.log("token0: ", token0VaultTotal.toString());
    console.log("token1: ", token1VaultTotal.toString());
    console.log("==================================================");

    console.log("perform vault swap to maintain users' vault exposure");
    let initialAmountBaseToken,
      initialAmountQuoteToken,
      currentAmountBaseToken,
      currentAmountQuoteToken;
    initialAmountBaseToken = token0VaultTotal;
    initialAmountQuoteToken = token1VaultTotal;
    currentAmountBaseToken = amount0Current3;
    currentAmountQuoteToken = amount1Current3;

    const swapAmountToken0 = amount0Current3.sub(token0VaultTotal);
    const swapAmountToken1 = amount1Current3.sub(token1VaultTotal);

    const MockSqrtPriceMath = await ethers.getContractFactory(
      "MockSqrtPriceMath"
    );
    const mockSqrtPriceMath = await MockSqrtPriceMath.deploy();

    const { price } = await algebraPool.globalState();
    const liquidity = await algebraPool.liquidity();

    const nextPrice = currentAmountBaseToken.gt(initialAmountBaseToken)
      ? // there is profit in base token that we swap to quote token
        await mockSqrtPriceMath.getNextSqrtPriceFromInput(
          price,
          liquidity,
          currentAmountBaseToken.sub(initialAmountBaseToken),
          true
        )
      : // there is loss in base token that is realized in quote token
        await mockSqrtPriceMath.getNextSqrtPriceFromInput(
          price,
          liquidity,
          initialAmountBaseToken.sub(currentAmountBaseToken),
          false
        );

    await vault.swap(
      currentAmountBaseToken.gt(initialAmountBaseToken),
      currentAmountBaseToken.sub(initialAmountBaseToken),
      nextPrice
    );
    console.log("==================================================");
    console.log("Vault balance after swap to maintain users' vault exposure: ");

    const { amount0Current: amount0Current4, amount1Current: amount1Current4 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amount0Current4.toString());
    console.log("token1 amount: ", amount1Current4.toString());
    console.log("==================================================");

    console.log("Add liquidity back to the algebra v3 pool");
    await vault.addLiquidity(
      bottomTick,
      topTick,
      amount0Current4,
      amount1Current4
    );

    console.log("==================================================");
    console.log(
      "Vault balance after providing the liquidity back to the algebra pool"
    );
    const { amount0Current: amount0Current5, amount1Current: amount1Current5 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amount0Current5.toString());
    console.log("token1 amount: ", amount1Current5.toString());
    console.log("==================================================");

    console.log("user 1 withdraws liquidity");
    const user1Amount = await vault.balanceOf(manager.address);
    await vault.burn(user1Amount);

    console.log("==================================================");
    console.log("Vault balance after user1 withdraws liquidity");
    const { amount0Current: amount0Current6, amount1Current: amount1Current6 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amount0Current6.toString());
    console.log("token1 amount: ", amount1Current6.toString());
    console.log("==================================================");

    console.log("user 2 withdraws liquidity");
    const user2Amount = await vault.balanceOf(newManager.address);
    await vault.connect(newManager).burn(user2Amount);

    console.log("==================================================");
    console.log("Vault balance after user2 withdraws liquidity");
    const { amount0Current: amount0Current7, amount1Current: amount1Current7 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amount0Current7.toString());
    console.log("token1 amount: ", amount1Current7.toString());
    console.log("==================================================");
  });
});
