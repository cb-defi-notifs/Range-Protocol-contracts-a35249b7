//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/agni/IAgniPool.sol";

contract SwapTest {
    function swapZeroForOne(address pool, int256 amountSpecified) external {
        (uint160 sqrtRatio, , , , , , ) = IAgniPool(pool).slot0();
        uint160 nextSqrtRatio = sqrtRatio +
            uint160(uint160(uint256(amountSpecified) * 2 ** 96) / IAgniPool(pool).liquidity());

        IAgniPool(pool).swap(
            address(msg.sender),
            false,
            amountSpecified,
            nextSqrtRatio,
            abi.encode(msg.sender)
        );
    }

    //    function washTrade(
    //        address pool,
    //        int256 amountSpecified,
    //        uint256 numTrades,
    //        uint256 ratio
    //    ) external {
    //        for (uint256 i = 0; i < numTrades; i++) {
    //            bool zeroForOne = i % ratio > 0;
    //            (uint160 sqrtRatio, , , , , , ) = IUniswapV3Pool(pool).slot0();
    //            IUniswapV3Pool(pool).swap(
    //                address(msg.sender),
    //                zeroForOne,
    //                amountSpecified,
    //                zeroForOne ? sqrtRatio - 1000 : sqrtRatio + 1000,
    //                abi.encode(msg.sender)
    //            );
    //        }
    //    }

    //    function getSwapResult(
    //        address pool,
    //        bool zeroForOne,
    //        int256 amountSpecified,
    //        uint160 sqrtPriceLimitX96
    //    ) external returns (int256 amount0Delta, int256 amount1Delta, uint160 nextSqrtRatio) {
    //        (amount0Delta, amount1Delta) = IUniswapV3Pool(pool).swap(
    //            address(msg.sender),
    //            zeroForOne,
    //            amountSpecified,
    //            sqrtPriceLimitX96,
    //            abi.encode(msg.sender)
    //        );
    //
    //        (nextSqrtRatio, , , , , , ) = IUniswapV3Pool(pool).slot0();
    //    }

    function agniSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        address sender = abi.decode(data, (address));

        if (amount0Delta > 0) {
            IERC20(IAgniPool(msg.sender).token0()).transferFrom(
                sender,
                msg.sender,
                uint256(amount0Delta)
            );
        } else if (amount1Delta > 0) {
            IERC20(IAgniPool(msg.sender).token1()).transferFrom(
                sender,
                msg.sender,
                uint256(amount1Delta)
            );
        }
    }
}
