//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IRangeProtocolVault} from "../interfaces/IRangeProtocolVault.sol";
import {IiZiSwapPool} from "../iZiSwap/interfaces/IiZiSwapPool.sol";
import {DataTypes} from "./DataTypes.sol";
import {MintMath} from "../iZiSwap/libraries/MintMath.sol";
import {MulDivMath} from "../iZiSwap/libraries/MulDivMath.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";

library VaultLib {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    int24 internal constant LEFT_MOST_PT = -800000;
    int24 internal constant RIGHT_MOST_PT = 800000;

    /// Performance fee cannot be set more than 10% of the fee earned from uniswap v3 pool.
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 1000;
    /// Managing fee cannot be set more than 1% of the total fee earned.
    uint16 public constant MAX_MANAGING_FEE_BPS = 100;

    event Minted(
        address indexed receiver,
        uint256 mintAmount,
        uint256 amount0In,
        uint256 amount1In
    );
    event Burned(
        address indexed receiver,
        uint256 burnAmount,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event LiquidityAdded(
        uint256 liquidityMinted,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0In,
        uint256 amount1In
    );
    event LiquidityRemoved(
        uint256 liquidityRemoved,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);
    event FeesUpdated(uint16 managingFee, uint16 performanceFee);
    event InThePositionStatusSet(bool inThePosition);
    event Swapped(bool zeroForOne, uint256 amount0, uint256 amount1);
    event TicksSet(int24 lowerTick, int24 upperTick);
    event MintStarted();

    function updatePoints(
        DataTypes.State storage state,
        int24 leftPoint,
        int24 rightPoint
    ) external {
        if (IRangeProtocolVault(address(this)).totalSupply() != 0 || state.inThePosition)
            revert VaultErrors.NotAllowedToUpdateTicks();
        _updatePoints(state, leftPoint, rightPoint);

        if (!state.mintStarted) {
            state.mintStarted = true;
            emit MintStarted();
        }
    }

    struct MintVars {
        uint256 totalSupply;
        bool inThePosition;
        uint160 sqrtPrice_96;
        int24 currentPoint;
        int24 leftPoint;
        int24 rightPoint;
        uint160 sqrtRate_96;
    }

    function mint(
        DataTypes.State storage state,
        uint256 mintAmount
    ) external returns (uint256 amountX, uint256 amountY) {
        if (mintAmount == 0) revert VaultErrors.InvalidMintAmount();
        if (!state.mintStarted) revert VaultErrors.MintNotStarted();
        IRangeProtocolVault vault = IRangeProtocolVault(address(this));

        MintVars memory mintVars;
        (mintVars.totalSupply, mintVars.inThePosition) = (vault.totalSupply(), state.inThePosition);

        IiZiSwapPool _pool = state.pool;
        (mintVars.sqrtPrice_96, mintVars.currentPoint, , , , , , ) = _pool.state();
        (mintVars.leftPoint, mintVars.rightPoint, mintVars.sqrtRate_96) = (
            state.leftPoint,
            state.rightPoint,
            _pool.sqrtRate_96()
        );

        if (mintVars.totalSupply > 0) {
            (uint256 amountXCurrent, uint256 amountYCurrent) = getUnderlyingBalances(state);
            amountX = MulDivMath.mulDivCeil(amountXCurrent, mintAmount, mintVars.totalSupply);
            amountY = MulDivMath.mulDivCeil(amountYCurrent, mintAmount, mintVars.totalSupply);
        } else if (mintVars.inThePosition) {
            // If total supply is zero then inThePosition must be set to accept tokenX and tokenY based on currently set currentPoints.
            // This branch will be executed for the first mint and as well as each time total supply is to be changed from zero to non-zero.

            (amountX, amountY) = MintMath.getAmountsForLiquidity(
                mintVars.sqrtPrice_96,
                mintVars.sqrtRate_96,
                mintVars.currentPoint,
                SafeCastUpgradeable.toUint128(mintAmount),
                mintVars.leftPoint,
                mintVars.rightPoint
            );
        } else {
            // If total supply is zero and the vault is not in the position then mint cannot be accepted based on the assumptions
            // that being out of the pool renders currently set currentPoints unusable and totalSupply being zero does not allow
            // calculating correct amounts of amountX and amountY to be accepted from the user.
            // This branch will be executed if all users remove their liquidity from the vault i.e. total supply is zero from non-zero and
            // the vault is out of the position i.e. no validcurrentPoint range to calculate the vault's mint shares.
            // Manager must call initialize function with validcurrentPoint ranges to enable the minting again.
            revert VaultErrors.MintNotAllowed();
        }

        DataTypes.UserVault storage userVault = state.userVaults[msg.sender];
        if (!userVault.exists) {
            userVault.exists = true;
            state.users.push(msg.sender);
        }
        if (amountX > 0) {
            userVault.tokenX += amountX;
            state.tokenX.safeTransferFrom(msg.sender, address(this), amountX);
        }
        if (amountY > 0) {
            userVault.tokenY += amountY;
            state.tokenY.safeTransferFrom(msg.sender, address(this), amountY);
        }

        vault.mintTo(msg.sender, mintAmount);
        if (mintVars.inThePosition) {
            uint128 liquidityMinted = MintMath.getLiquidityForAmounts(
                mintVars.leftPoint,
                mintVars.rightPoint,
                uint128(amountX),
                uint128(amountY),
                mintVars.currentPoint,
                mintVars.sqrtPrice_96,
                mintVars.sqrtRate_96
            );
            _pool.mint(address(this), mintVars.leftPoint, mintVars.rightPoint, liquidityMinted, "");
        }

        emit Minted(msg.sender, mintAmount, amountX, amountY);
    }

    struct BurnVars {
        uint256 totalSupply;
        uint256 balanceBefore;
        IERC20Upgradeable tokenX;
        IERC20Upgradeable tokenY;
        uint256 managerBalanceX;
        uint256 managerBalanceY;
    }

    function burn(
        DataTypes.State storage state,
        uint256 burnAmount
    ) external returns (uint256 amountX, uint256 amountY) {
        if (burnAmount == 0) revert VaultErrors.InvalidBurnAmount();
        IRangeProtocolVault vault = IRangeProtocolVault(address(this));

        BurnVars memory burnVars;
        (
            burnVars.totalSupply,
            burnVars.balanceBefore,
            burnVars.tokenX,
            burnVars.tokenY,
            burnVars.managerBalanceX,
            burnVars.managerBalanceY
        ) = (
            vault.totalSupply(),
            vault.balanceOf(msg.sender),
            state.tokenX,
            state.tokenY,
            state.managerBalanceX,
            state.managerBalanceY
        );
        vault.burnFrom(msg.sender, burnAmount);

        if (state.inThePosition) {
            IiZiSwapPool.LiquidityData memory liquidityData = state.pool.liquidity(
                getPositionID(state)
            );
            uint256 liquidityBurned_ = MulDivMath.mulDivFloor(
                burnAmount,
                liquidityData.liquidity,
                burnVars.totalSupply
            );
            uint128 liquidityBurned = SafeCastUpgradeable.toUint128(liquidityBurned_);
            (uint256 burn0, uint256 burn1, uint256 fee0, uint256 fee1) = _withdraw(
                state,
                liquidityBurned
            );

            _applyPerformanceFee(state, fee0, fee1);
            (fee0, fee1) = _netPerformanceFees(state, fee0, fee1);
            emit FeesEarned(fee0, fee1);

            uint256 passiveBalance0 = burnVars.tokenX.balanceOf(address(this)) - burn0;
            uint256 passiveBalance1 = burnVars.tokenY.balanceOf(address(this)) - burn1;
            if (passiveBalance0 > burnVars.managerBalanceX)
                passiveBalance0 -= burnVars.managerBalanceX;
            if (passiveBalance1 > burnVars.managerBalanceY)
                passiveBalance1 -= burnVars.managerBalanceY;

            amountX =
                burn0 +
                MulDivMath.mulDivFloor(passiveBalance0, burnAmount, burnVars.totalSupply);
            amountY =
                burn1 +
                MulDivMath.mulDivFloor(passiveBalance1, burnAmount, burnVars.totalSupply);
        } else {
            (uint256 amountXCurrent, uint256 amountYCurrent) = getUnderlyingBalances(state);
            amountX = MulDivMath.mulDivFloor(amountXCurrent, burnAmount, burnVars.totalSupply);
            amountY = MulDivMath.mulDivFloor(amountYCurrent, burnAmount, burnVars.totalSupply);
        }

        _applyManagingFee(state, amountX, amountY);
        (uint256 amountXAfterFee, uint256 amountYAfterFee) = _netManagingFees(
            state,
            amountX,
            amountY
        );

        DataTypes.UserVault storage userVault = state.userVaults[msg.sender];
        if (amountX > 0) {
            userVault.tokenX =
                (userVault.tokenX * (burnVars.balanceBefore - burnAmount)) /
                burnVars.balanceBefore;
            burnVars.tokenX.safeTransfer(msg.sender, amountXAfterFee);
        }
        if (amountY > 0) {
            userVault.tokenY =
                (userVault.tokenY * (burnVars.balanceBefore - burnAmount)) /
                burnVars.balanceBefore;
            burnVars.tokenY.safeTransfer(msg.sender, amountYAfterFee);
        }

        emit Burned(msg.sender, burnAmount, amountXAfterFee, amountYAfterFee);
    }

    function removeLiquidity(DataTypes.State storage state) external {
        IiZiSwapPool.LiquidityData memory liquidityData = state.pool.liquidity(
            getPositionID(state)
        );
        if (liquidityData.liquidity > 0) {
            int24 _leftPoint = state.leftPoint;
            int24 _rightPoint = state.rightPoint;
            (uint256 amountX, uint256 amountY, uint256 fee0, uint256 fee1) = _withdraw(
                state,
                liquidityData.liquidity
            );

            emit LiquidityRemoved(
                liquidityData.liquidity,
                _leftPoint,
                _rightPoint,
                amountX,
                amountY
            );

            _applyPerformanceFee(state, fee0, fee1);
            (fee0, fee1) = _netPerformanceFees(state, fee0, fee1);
            emit FeesEarned(fee0, fee1);
        }

        // TicksSet event is not emitted here since the emitting would create a new position on subgraph but
        // the following statement is to only disallow any liquidity provision through the vault unless done
        // by manager (taking into account any features added in future).
        state.leftPoint = state.rightPoint;
        state.inThePosition = false;
        emit InThePositionStatusSet(false);
    }

    function swap(
        DataTypes.State storage state,
        bool zeroForOne,
        uint128 swapAmount,
        int24 pointLimit
    ) external returns (uint256 amountX, uint256 amountY) {
        if (zeroForOne)
            (amountX, amountY) = state.pool.swapX2Y(
                address(this),
                swapAmount,
                pointLimit,
                bytes("")
            );
        else
            (amountX, amountY) = state.pool.swapY2X(
                address(this),
                swapAmount,
                pointLimit,
                bytes("")
            );

        emit Swapped(zeroForOne, amountX, amountY);
    }

    function addLiquidity(
        DataTypes.State storage state,
        int24 newLeftPoint,
        int24 newRightPoint,
        uint128 amountX,
        uint128 amountY
    ) external returns (uint256 remainingAmountX, uint256 remainingAmountY) {
        _validateTicks(newLeftPoint, newRightPoint, state.pointDelta);
        if (state.inThePosition) revert VaultErrors.LiquidityAlreadyAdded();

        IiZiSwapPool _pool = state.pool;

        (uint160 sqrtPrice_96, int24 currentPoint, , , , , , ) = _pool.state();
        uint128 baseLiquidity = MintMath.getLiquidityForAmounts(
            newLeftPoint,
            newRightPoint,
            amountX,
            amountY,
            currentPoint,
            sqrtPrice_96,
            _pool.sqrtRate_96()
        );

        if (baseLiquidity > 0) {
            (uint256 amountDeposited0, uint256 amountDeposited1) = _pool.mint(
                address(this),
                newLeftPoint,
                newRightPoint,
                baseLiquidity,
                ""
            );

            emit LiquidityAdded(
                baseLiquidity,
                newLeftPoint,
                newRightPoint,
                amountDeposited0,
                amountDeposited1
            );

            // Should return remaining token number for swap
            remainingAmountX = amountX - amountDeposited0;
            remainingAmountY = amountY - amountDeposited1;
            state.leftPoint = newLeftPoint;
            state.rightPoint = newRightPoint;
            emit TicksSet(newLeftPoint, newRightPoint);

            state.inThePosition = true;
            emit InThePositionStatusSet(true);
        }
    }

    function pullFeeFromPool(DataTypes.State storage state) external {
        (, , uint256 fee0, uint256 fee1) = _withdraw(state, 0);
        _applyPerformanceFee(state, fee0, fee1);
        (fee0, fee1) = _netPerformanceFees(state, fee0, fee1);
        emit FeesEarned(fee0, fee1);
    }

    function collectManager(DataTypes.State storage state, address manager) external {
        uint256 amountX = state.managerBalanceX;
        uint256 amountY = state.managerBalanceY;
        state.managerBalanceX = 0;
        state.managerBalanceY = 0;

        if (amountX > 0) state.tokenX.safeTransfer(manager, amountX);
        if (amountY > 0) state.tokenY.safeTransfer(manager, amountY);
    }

    function updateFees(
        DataTypes.State storage state,
        uint16 newManagingFee,
        uint16 newPerformanceFee
    ) external {
        if (newManagingFee > MAX_MANAGING_FEE_BPS) revert VaultErrors.InvalidManagingFee();
        if (newPerformanceFee > MAX_PERFORMANCE_FEE_BPS) revert VaultErrors.InvalidPerformanceFee();

        state.managingFee = newManagingFee;
        state.performanceFee = newPerformanceFee;
        emit FeesUpdated(newManagingFee, newPerformanceFee);
    }

    struct MintAmountsVars {
        uint256 totalSupply;
        uint160 sqrtPrice_96;
        uint160 sqrtRate_96;
        int24 currentPoint;
        int24 leftPoint;
        int24 rightPoint;
    }

    function getMintAmounts(
        DataTypes.State storage state,
        uint128 amountXMax,
        uint128 amountYMax
    ) external view returns (uint256 amountX, uint256 amountY, uint256 mintAmount) {
        if (!state.mintStarted) revert VaultErrors.MintNotStarted();

        MintAmountsVars memory mintAmountsVars;
        (mintAmountsVars.totalSupply) = (IRangeProtocolVault(address(this)).totalSupply());

        if (mintAmountsVars.totalSupply > 0) {
            (amountX, amountY, mintAmount) = _calcMintAmounts(
                state,
                mintAmountsVars.totalSupply,
                amountXMax,
                amountYMax
            );
        } else {
            (mintAmountsVars.sqrtPrice_96, mintAmountsVars.currentPoint, , , , , , ) = state
                .pool
                .state();
            (mintAmountsVars.leftPoint, mintAmountsVars.rightPoint, mintAmountsVars.sqrtRate_96) = (
                state.leftPoint,
                state.rightPoint,
                state.pool.sqrtRate_96()
            );
            uint128 newLiquidity = MintMath.getLiquidityForAmounts(
                mintAmountsVars.leftPoint,
                mintAmountsVars.rightPoint,
                amountXMax,
                amountYMax,
                mintAmountsVars.currentPoint,
                mintAmountsVars.sqrtPrice_96,
                mintAmountsVars.sqrtRate_96
            );
            mintAmount = uint256(newLiquidity);
            (amountX, amountY) = MintMath.getAmountsForLiquidity(
                mintAmountsVars.sqrtPrice_96,
                mintAmountsVars.sqrtRate_96,
                mintAmountsVars.currentPoint,
                newLiquidity,
                mintAmountsVars.leftPoint,
                mintAmountsVars.rightPoint
            );
        }
    }

    //    function getUnderlyingBalancesAtPrice(
    //        uint160 sqrtPrice_96
    //    ) external view override returns (uint256 amountXCurrent, uint256 amountYCurrent) {
    //        (, int24 currentPoint, , , , , , ) = pool.state();
    //        return _getUnderlyingBalances(sqrtPrice_96, currentPoint);
    //    }

    function getCurrentFees(
        DataTypes.State storage state
    ) external view returns (uint256 fee0, uint256 fee1) {
        (, int24 currentPoint, , , , , , ) = state.pool.state();
        IiZiSwapPool.LiquidityData memory liquidityData = state.pool.liquidity(
            getPositionID(state)
        );

        fee0 =
            _feesEarned(
                state,
                true,
                liquidityData.lastFeeScaleX_128,
                currentPoint,
                liquidityData.liquidity
            ) +
            liquidityData.tokenOwedX;
        fee1 =
            _feesEarned(
                state,
                false,
                liquidityData.lastFeeScaleY_128,
                currentPoint,
                liquidityData.liquidity
            ) +
            liquidityData.tokenOwedY;
        (fee0, fee1) = _netPerformanceFees(state, fee0, fee1);
    }

    function userCount(DataTypes.State storage state) external view returns (uint256) {
        return state.users.length;
    }

    function getUnderlyingBalances(
        DataTypes.State storage state
    ) public view returns (uint256 amountXCurrent, uint256 amountYCurrent) {
        (uint160 sqrtPrice_96, int24 currentPoint, , , , , , ) = state.pool.state();
        return _getUnderlyingBalances(state, sqrtPrice_96, currentPoint);
    }

    function getUnderlyingBalancesByShare(
        DataTypes.State storage state,
        uint256 shares
    ) external view returns (uint256 amountX, uint256 amountY) {
        uint256 _totalSupply = IRangeProtocolVault(address(this)).totalSupply();
        if (_totalSupply != 0) {
            // getUnderlyingBalances already applies performanceFee
            (uint256 amountXCurrent, uint256 amountYCurrent) = getUnderlyingBalances(state);
            amountX = (shares * amountXCurrent) / _totalSupply;
            amountY = (shares * amountYCurrent) / _totalSupply;
            // apply managing fee
            (amountX, amountY) = _netManagingFees(state, amountX, amountY);
        }
    }

    function _beforeTokenTransfer(
        DataTypes.State storage state,
        address from,
        address to,
        uint256 amount
    ) external {
        // for mint and burn the user vaults adjustment are handled in the respective functions
        if (from == address(0x0) || to == address(0x0)) return;

        DataTypes.UserVault storage toUserVault = state.userVaults[to];
        DataTypes.UserVault storage fromUserVault = state.userVaults[from];

        if (!toUserVault.exists) {
            toUserVault.exists = true;
            state.users.push(to);
        }
        uint256 senderBalance = IRangeProtocolVault(address(this)).balanceOf(from);
        uint256 tokenXAmount = fromUserVault.tokenX -
        (fromUserVault.tokenX * (senderBalance - amount)) /
        senderBalance;

        uint256 tokenYAmount = fromUserVault.tokenY -
        (fromUserVault.tokenY * (senderBalance - amount)) /
        senderBalance;

        fromUserVault.tokenX -= tokenXAmount;
        fromUserVault.tokenY -= tokenYAmount;

        toUserVault.tokenX += tokenXAmount;
        toUserVault.tokenY += tokenYAmount;
    }

    function getPositionID(DataTypes.State storage state) public view returns (bytes32 positionID) {
        return keccak256(abi.encodePacked(address(this), state.leftPoint, state.rightPoint));
    }

    function _getUnderlyingBalances(
        DataTypes.State storage state,
        uint160 sqrtPrice_96,
        int24 currentPoint
    ) internal view returns (uint256 amountXCurrent, uint256 amountYCurrent) {
        IiZiSwapPool.LiquidityData memory liquidityData = state.pool.liquidity(
            getPositionID(state)
        );
        uint256 fee0;
        uint256 fee1;
        if (liquidityData.liquidity != 0) {
            (amountXCurrent, amountYCurrent) = MintMath.getAmountsForLiquidity(
                sqrtPrice_96,
                state.pool.sqrtRate_96(),
                currentPoint,
                liquidityData.liquidity,
                state.leftPoint,
                state.rightPoint
            );
            fee0 =
                _feesEarned(
                    state,
                    true,
                    liquidityData.lastFeeScaleX_128,
                    currentPoint,
                    liquidityData.liquidity
                ) +
                liquidityData.tokenOwedX;
            fee1 =
                _feesEarned(
                    state,
                    false,
                    liquidityData.lastFeeScaleY_128,
                    currentPoint,
                    liquidityData.liquidity
                ) +
                liquidityData.tokenOwedY;
            (fee0, fee1) = _netPerformanceFees(state, fee0, fee1);
        }

        uint256 passiveBalance0 = fee0 + state.tokenX.balanceOf(address(this));
        uint256 passiveBalance1 = fee1 + state.tokenY.balanceOf(address(this));

        amountXCurrent += passiveBalance0 > state.managerBalanceX
            ? passiveBalance0 - state.managerBalanceX
            : passiveBalance0;
        amountYCurrent += passiveBalance1 > state.managerBalanceY
            ? passiveBalance1 - state.managerBalanceY
            : passiveBalance1;
    }

    function _withdraw(
        DataTypes.State storage state,
        uint128 liquidity
    ) private returns (uint256 burn0, uint256 burn1, uint256 fee0, uint256 fee1) {
        int24 _leftPoint = state.leftPoint;
        int24 _rightPoint = state.rightPoint;
        uint256 preBalance0 = state.tokenX.balanceOf(address(this));
        uint256 preBalance1 = state.tokenY.balanceOf(address(this));
        (burn0, burn1) = state.pool.burn(_leftPoint, _rightPoint, liquidity);
        state.pool.collect(
            address(this),
            _leftPoint,
            _rightPoint,
            type(uint128).max,
            type(uint128).max
        );
        fee0 = state.tokenX.balanceOf(address(this)) - preBalance0 - burn0;
        fee1 = state.tokenY.balanceOf(address(this)) - preBalance1 - burn1;
    }

    function _calcMintAmounts(
        DataTypes.State storage state,
        uint256 totalSupply,
        uint256 amountXMax,
        uint256 amountYMax
    ) private view returns (uint256 amountX, uint256 amountY, uint256 mintAmount) {
        (uint256 amountXCurrent, uint256 amountYCurrent) = getUnderlyingBalances(state);
        if (amountXCurrent == 0 && amountYCurrent > 0) {
            mintAmount = MulDivMath.mulDivFloor(amountYMax, totalSupply, amountYCurrent);
        } else if (amountYCurrent == 0 && amountXCurrent > 0) {
            mintAmount = MulDivMath.mulDivFloor(amountXMax, totalSupply, amountXCurrent);
        } else if (amountXCurrent == 0 && amountYCurrent == 0) {
            revert VaultErrors.ZeroUnderlyingBalance();
        } else {
            uint256 amountXMint = MulDivMath.mulDivFloor(amountXMax, totalSupply, amountXCurrent);
            uint256 amountYMint = MulDivMath.mulDivFloor(amountYMax, totalSupply, amountYCurrent);
            if (amountXMint == 0 || amountYMint == 0) revert VaultErrors.ZeroMintAmount();
            mintAmount = amountXMint < amountYMint ? amountXMint : amountYMint;
        }

        amountX = MulDivMath.mulDivCeil(mintAmount, amountXCurrent, totalSupply);
        amountY = MulDivMath.mulDivCeil(mintAmount, amountYCurrent, totalSupply);
    }

    function _feesEarned(
        DataTypes.State storage state,
        bool isZero,
        uint256 feeGrowthInsideLast,
        int24 point,
        uint128 liquidity
    ) private view returns (uint256 fee) {
        IiZiSwapPool _pool = state.pool;
        uint256 feeGrowthOutsideLower;
        uint256 feeGrowthOutsideUpper;
        uint256 feeGrowthGlobal;
        if (isZero) {
            feeGrowthGlobal = state.pool.feeScaleX_128();
            IiZiSwapPool.PointData memory lowerPointData = _pool.points(state.leftPoint);
            IiZiSwapPool.PointData memory upperPointData = _pool.points(state.rightPoint);
            feeGrowthOutsideLower = lowerPointData.accFeeXOut_128;
            feeGrowthOutsideUpper = upperPointData.accFeeXOut_128;
        } else {
            feeGrowthGlobal = _pool.feeScaleY_128();
            IiZiSwapPool.PointData memory lowerPointData = _pool.points(state.leftPoint);
            IiZiSwapPool.PointData memory upperPointData = _pool.points(state.rightPoint);
            feeGrowthOutsideLower = lowerPointData.accFeeYOut_128;
            feeGrowthOutsideUpper = upperPointData.accFeeYOut_128;
        }

        unchecked {
            uint256 feeGrowthBelow;
            if (point >= state.leftPoint) {
                feeGrowthBelow = feeGrowthOutsideLower;
            } else {
                feeGrowthBelow = feeGrowthGlobal - feeGrowthOutsideLower;
            }

            uint256 feeGrowthAbove;
            if (point < state.rightPoint) {
                feeGrowthAbove = feeGrowthOutsideUpper;
            } else {
                feeGrowthAbove = feeGrowthGlobal - feeGrowthOutsideUpper;
            }
            uint256 feeGrowthInside = feeGrowthGlobal - feeGrowthBelow - feeGrowthAbove;

            fee = MulDivMath.mulDivFloor(
                liquidity,
                feeGrowthInside - feeGrowthInsideLast,
                0x100000000000000000000000000000000
            );
        }
    }

    function _applyManagingFee(
        DataTypes.State storage state,
        uint256 amountX,
        uint256 amountY
    ) private {
        uint256 _managingFee = state.managingFee;
        state.managerBalanceX += (amountX * _managingFee) / 10_000;
        state.managerBalanceY += (amountY * _managingFee) / 10_000;
    }

    function _applyPerformanceFee(
        DataTypes.State storage state,
        uint256 fee0,
        uint256 fee1
    ) private {
        uint256 _performanceFee = state.performanceFee;
        state.managerBalanceX += (fee0 * _performanceFee) / 10_000;
        state.managerBalanceY += (fee1 * _performanceFee) / 10_000;
    }

    function _netManagingFees(
        DataTypes.State storage state,
        uint256 amountX,
        uint256 amountY
    ) private view returns (uint256 amountXAfterFee, uint256 amountYAfterFee) {
        uint256 _managingFee = state.managingFee;
        uint256 deduct0 = (amountX * _managingFee) / 10_000;
        uint256 deduct1 = (amountY * _managingFee) / 10_000;
        amountXAfterFee = amountX - deduct0;
        amountYAfterFee = amountY - deduct1;
    }

    function _netPerformanceFees(
        DataTypes.State storage state,
        uint256 rawFee0,
        uint256 rawFee1
    ) private view returns (uint256 fee0AfterDeduction, uint256 fee1AfterDeduction) {
        uint256 _performanceFee = state.performanceFee;
        uint256 deduct0 = (rawFee0 * _performanceFee) / 10_000;
        uint256 deduct1 = (rawFee1 * _performanceFee) / 10_000;
        fee0AfterDeduction = rawFee0 - deduct0;
        fee1AfterDeduction = rawFee1 - deduct1;
    }

    function _updatePoints(
        DataTypes.State storage state,
        int24 _leftPoint,
        int24 _rightPoint
    ) private {
        _validateTicks(_leftPoint, _rightPoint, state.pointDelta);
        state.leftPoint = _leftPoint;
        state.rightPoint = _rightPoint;
        state.inThePosition = true;

        emit InThePositionStatusSet(true);
        emit TicksSet(_leftPoint, _rightPoint);
    }

    function _validateTicks(int24 _leftPoint, int24 _rightPoint, int24 _pointDelta) private pure {
        if (_leftPoint < LEFT_MOST_PT || _rightPoint > RIGHT_MOST_PT)
            revert VaultErrors.TicksOutOfRange();

        if (
            _leftPoint >= _rightPoint ||
            _leftPoint % _pointDelta != 0 ||
            _rightPoint % _pointDelta != 0
        ) revert VaultErrors.InvalidTicksSpacing();
    }
}
