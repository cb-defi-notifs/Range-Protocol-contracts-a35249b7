import { ethers } from "hardhat";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import {
  IERC20,
  IIiZiSwapFactory,
  IiZiSwapPool,
  RangeProtocolVault,
  RangeProtocolFactory,
  SwapTest,
} from "../typechain";
import { bn, getInitializeData, parseEther } from "./common";
import { beforeEach } from "mocha";
import { BigNumber } from "ethers";

let factory: RangeProtocolFactory;
let vaultImpl: RangeProtocolVault;
let vault: RangeProtocolVault;
let iZiSwapFactory: IIiZiSwapFactory;
let iZiSwapPool: IiZiSwapPool;
let token0: IERC20;
let token1: IERC20;
let manager: SignerWithAddress;
let trader: SignerWithAddress;
let nonManager: SignerWithAddress;
let newManager: SignerWithAddress;
let user2: SignerWithAddress;
let lpProvider: SignerWithAddress;
const poolFee = 10000;
const name = "Test Token";
const symbol = "TT";
const amountX: BigNumber = parseEther("2");
const amountY: BigNumber = parseEther("3");
let initializeData: any;
const lowerTick = -10000;
const upperTick = 20000;

describe("RangeProtocolVault::exposure", () => {
  before(async () => {
    [manager, nonManager, user2, newManager, trader, lpProvider] =
      await ethers.getSigners();
    iZiSwapFactory = await ethers.getContractAt(
      "IiZiSwapFactory",
      "0x93BB94a0d5269cb437A1F71FF3a77AB753844422"
    );

    const RangeProtocolFactory = await ethers.getContractFactory(
      "RangeProtocolFactory"
    );
    factory = (await RangeProtocolFactory.deploy(
      iZiSwapFactory.address
    )) as RangeProtocolFactory;

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token0 = (await MockERC20.deploy()) as IERC20;
    token1 = (await MockERC20.deploy()) as IERC20;

    if (bn(token0.address).gt(token1.address)) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await iZiSwapFactory.newPool(token0.address, token1.address, poolFee, 1);
    iZiSwapPool = (await ethers.getContractAt(
      "IiZiSwapPool",
      await iZiSwapFactory.pool(token0.address, token1.address, poolFee)
    )) as IiZiSwapPool;

    const VaultLib = await ethers.getContractFactory("VaultLib");
    const vaultLib = await VaultLib.deploy();
    const RangeProtocolVault = await ethers.getContractFactory(
      "RangeProtocolVault",
      {
        libraries: {
          VaultLib: vaultLib.address,
        },
      }
    );
    vaultImpl = (await RangeProtocolVault.deploy()) as RangeProtocolVault;

    initializeData = getInitializeData({
      managerAddress: manager.address,
      name,
      symbol,
    });

    await factory.createVault(
      token0.address,
      token1.address,
      poolFee,
      vaultImpl.address,
      initializeData
    );

    const vaultAddress = await factory.getVaultAddresses(0, 0);
    vault = (await ethers.getContractAt(
      "RangeProtocolVault",
      vaultAddress[0]
    )) as RangeProtocolVault;
    await expect(vault.connect(manager).updatePoints(lowerTick, upperTick));
  });

  beforeEach(async () => {
    await token0.approve(vault.address, amountX.mul(bn(2)));
    await token1.approve(vault.address, amountY.mul(bn(2)));
  });

  it("should mint with zero totalSupply of vault shares", async () => {
    await token0.connect(lpProvider).mint();
    await token1.connect(lpProvider).mint();

    const {
      mintAmount: mintAmount1,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountX: amountXMint1,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountY: amountYMint1,
    } = await vault.getMintAmounts(amountX, amountY);

    await expect(vault.mint(mintAmount1, [amountXMint1, amountYMint1]))
      .to.emit(vault, "Minted")
      .withArgs(
        manager.address,
        mintAmount1,
        amountXMint1.toString(),
        amountYMint1.toString()
      );

    console.log("Users 1:");
    console.log("mint amount: ", mintAmount1.toString());
    console.log("token0 amount: ", amountXMint1.toString());
    console.log("token1 amount: ", amountYMint1.toString());
    console.log("==================================================");

    await token0.connect(newManager).mint();
    await token1.connect(newManager).mint();

    const {
      mintAmount: mintAmount2,
      amountX: amountXMint2,
      amountY: amountYMint2,
    } = await vault.getMintAmounts(amountX, amountY);
    await token0.connect(newManager).approve(vault.address, amountXMint2);
    await token1.connect(newManager).approve(vault.address, amountYMint2);

    await vault
      .connect(newManager)
      .mint(mintAmount2, [amountXMint2, amountYMint2]);

    console.log("Users 2:");
    console.log("mint amount: ", mintAmount1.toString());
    console.log("token0 amount: ", amountXMint2.toString());
    console.log("token1 amount: ", amountYMint2.toString());
    console.log("==================================================");

    const SwapTest = await ethers.getContractFactory("SwapTest");
    const swapTest = (await SwapTest.deploy()) as SwapTest;

    const { amountXCurrent: amountXCurrent1, amountYCurrent: amountYCurrent1 } =
      await vault.getUnderlyingBalances();
    console.log("Vault balance: ");
    console.log("token0 amount: ", amountXCurrent1.toString());
    console.log("token1 amount: ", amountYCurrent1.toString());
    console.log("==================================================");

    console.log(
      "perform external swap " + amountY.toString(),
      " of token1 to token0 to move price"
    );
    console.log("==================================================");

    await token0.connect(trader).mint();
    await token1.connect(trader).mint();

    await token0.connect(trader).approve(swapTest.address, amountX);
    await token1.connect(trader).approve(swapTest.address, amountY);

    await swapTest
      .connect(trader)
      .swapOneForZero(iZiSwapPool.address, amountY.div(bn(4)));

    const { amountXCurrent: amountXCurrent2, amountYCurrent: amountYCurrent2 } =
      await vault.getUnderlyingBalances();
    console.log("Vault balance after swap: ");
    console.log("token0 amount: ", amountXCurrent2.toString());
    console.log("token1 amount: ", amountYCurrent2.toString());
    console.log("==================================================");

    console.log("User2 mints for the second time (after price movement)");
    await token0.connect(newManager).mint();
    await token1.connect(newManager).mint();

    const {
      mintAmount: mintAmount3,
      amountX: amountXMint3,
      amountY: amountYMint3,
    } = await vault.getMintAmounts(amountX, amountY);
    await token0.connect(newManager).approve(vault.address, amountXMint3);
    await token1.connect(newManager).approve(vault.address, amountYMint3);
    console.log("Users 2:");
    console.log(
      "vault shares before: ",
      (await vault.balanceOf(newManager.address)).toString()
    );

    await vault
      .connect(newManager)
      .mint(mintAmount3, [amountXMint3, amountYMint3]);
    console.log(
      "vault shares after: ",
      (await vault.balanceOf(newManager.address)).toString()
    );

    console.log("==================================================");

    console.log("Vault balance after user2 mints for the second time: ");

    const { amountXCurrent: amountXCurrent3, amountYCurrent: amountYCurrent3 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amountXCurrent3.toString());
    console.log("token1 amount: ", amountYCurrent3.toString());
    console.log("==================================================");

    console.log("Remove liquidity from uniswap pool");
    await vault.removeLiquidity();
    console.log("==================================================");

    console.log("Total users vault amounts based on their initial deposits");
    const userVaults = await vault.getUserVaults(0, 0);
    const { tokenXVaultTotal, tokenYVaultTotal } = userVaults.reduce(
      (acc, { tokenX, tokenY }) => {
        return {
          tokenXVaultTotal: acc.tokenXVaultTotal.add(tokenX),
          tokenYVaultTotal: acc.tokenYVaultTotal.add(tokenY),
        };
      },
      {
        tokenXVaultTotal: bn(0),
        tokenYVaultTotal: bn(0),
      }
    );
    console.log("token0: ", tokenXVaultTotal.toString());
    console.log("token1: ", tokenYVaultTotal.toString());
    console.log("==================================================");

    console.log("perform vault swap to maintain users' vault exposure");

    await token0.transfer(swapTest.address, amountX);
    await token1.transfer(swapTest.address, amountY);
    await swapTest.mint(await vault.pool(), ethers.utils.parseEther("0.00001"));
    let initialAmountBaseToken,
      initialAmountQuoteToken,
      currentAmountBaseToken,
      currentAmountQuoteToken;
    initialAmountBaseToken = tokenXVaultTotal;
    initialAmountQuoteToken = tokenYVaultTotal;
    currentAmountBaseToken = amountXCurrent3;
    currentAmountQuoteToken = amountYCurrent3;

    let { sqrtPrice_96, currentPoint } = await iZiSwapPool.state();
    const nextPoint = currentAmountBaseToken.gt(initialAmountBaseToken)
      ? // there is profit in base token that we swap to quote token
        currentPoint - 100
      : // there is loss in base token that is realized in quote token
        currentPoint + 100;

    const zeroForOne = currentAmountBaseToken.gt(initialAmountBaseToken);
    const { amountX: _amountX, amountY: _amountY } =
      await vault.callStatic.swap(
        zeroForOne,
        currentAmountBaseToken.sub(initialAmountBaseToken),
        nextPoint,
        0
      );
    await vault.swap(
      zeroForOne,
      currentAmountBaseToken.sub(initialAmountBaseToken),
      nextPoint,
      zeroForOne ? _amountY : _amountX
    );
    console.log("==================================================");
    console.log("Vault balance after swap to maintain users' vault exposure: ");

    const { amountXCurrent: amountXCurrent4, amountYCurrent: amountYCurrent4 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amountXCurrent4.toString());
    console.log("token1 amount: ", amountYCurrent4.toString());
    console.log("==================================================");

    console.log("Add liquidity back to the uniswap v3 pool");
    // eslint-disable-next-line @typescript-eslint/naming-convention
    const MockMintMath = await ethers.getContractFactory("MockMintMath");
    const mockMintMath = await MockMintMath.deploy();

    ({ sqrtPrice_96, currentPoint } = await iZiSwapPool.state());
    const sqrtRate_96 = await iZiSwapPool.sqrtRate_96();
    const liquidity = await mockMintMath.getLiquidityForAmounts(
      lowerTick,
      upperTick,
      amountXCurrent4,
      amountYCurrent4,
      currentPoint,
      sqrtPrice_96,
      sqrtRate_96
    );
    const { x, y } = await mockMintMath.getAmountsForLiquidity(
      sqrtPrice_96,
      sqrtRate_96,
      currentPoint,
      liquidity,
      lowerTick,
      upperTick
    );
    await vault.addLiquidity(
      lowerTick,
      upperTick,
      amountXCurrent4,
      amountYCurrent4,
      [x.mul(9900).div(10000), y.mul(9900).div(10000)]
    );

    console.log("==================================================");
    console.log(
      "Vault balance after providing the liquidity back to the uniswap pool"
    );
    const { amountXCurrent: amountXCurrent5, amountYCurrent: amountYCurrent5 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amountXCurrent5.toString());
    console.log("token1 amount: ", amountYCurrent5.toString());
    console.log("==================================================");

    console.log("user 1 withdraws liquidity");
    const user1Amount = await vault.balanceOf(manager.address);
    let { amountX: minAmountX, amountY: minAmountY } =
      await vault.getUnderlyingBalancesByShare(user1Amount);
    console.log(minAmountX.toString(), minAmountY.toString());
    await vault.burn(user1Amount, [
      minAmountX.mul(9900).div(10000),
      minAmountY.mul(9900).div(10000),
    ]);

    console.log("==================================================");
    console.log("Vault balance after user1 withdraws liquidity");
    const { amountXCurrent: amountXCurrent6, amountYCurrent: amountYCurrent6 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amountXCurrent6.toString());
    console.log("token1 amount: ", amountYCurrent6.toString());
    console.log("==================================================");

    console.log("user 2 withdraws liquidity");
    const user2Amount = await vault.balanceOf(newManager.address);
    ({ amountX: minAmountX, amountY: minAmountY } =
      await vault.getUnderlyingBalancesByShare(user2Amount));
    await vault
      .connect(newManager)
      .burn(user2Amount, [
        minAmountX.mul(9900).div(10000),
        minAmountY.mul(9900).div(10000),
      ]);

    console.log("==================================================");
    console.log("Vault balance after user2 withdraws liquidity");
    const { amountXCurrent: amountXCurrent7, amountYCurrent: amountYCurrent7 } =
      await vault.getUnderlyingBalances();
    console.log("token0 amount: ", amountXCurrent7.toString());
    console.log("token1 amount: ", amountYCurrent7.toString());
    console.log("==================================================");
  });
});
