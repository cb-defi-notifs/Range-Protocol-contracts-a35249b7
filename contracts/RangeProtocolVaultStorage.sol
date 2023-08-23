//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {IRangeProtocolVault} from "./interfaces/IRangeProtocolVault.sol";
import {IiZiSwapPool} from "./iZiSwap/interfaces/IiZiSwapPool.sol";

/**
 * @notice RangeProtocolVaultStorage a storage contract for RangeProtocolVault
 */
abstract contract RangeProtocolVaultStorage is IRangeProtocolVault {
    DataTypes.State internal state;

    function leftPoint() external override view returns (int24) {
        return state.leftPoint;
    }

    function rightPoint() external override view returns (int24) {
        return state.rightPoint;
    }

    function pointDelta() external override view returns (int24) {
        return state.pointDelta;
    }

    function pool() external override view returns (IiZiSwapPool) {
        return state.pool;
    }

    function tokenX() external override view returns (IERC20Upgradeable) {
        return state.tokenX;
    }

    function tokenY() external override view returns (IERC20Upgradeable) {
        return state.tokenY;
    }

    function inThePosition() external override view returns (bool) {
        return state.inThePosition;
    }

    function mintStarted() external override view returns (bool) {
        return state.mintStarted;
    }

    function factory() external override view returns (address) {
        return state.factory;
    }

    function managingFee() external override view returns (uint16) {
        return state.managingFee;
    }

    function performanceFee() external override view returns (uint16) {
        return state.performanceFee;
    }

    function managerBalanceX() external override view returns (uint256) {
        return state.managerBalanceX;
    }

    function managerBalanceY() external override view returns (uint256) {
        return state.managerBalanceY;
    }

    function userVaults(address user) external override view returns (DataTypes.UserVault memory) {
        return state.userVaults[user];
    }

    function users(uint256 idx) external override view returns (address) {
        return state.users[idx];
    }

    function getUserVaults(
        uint256 fromIdx,
        uint256 toIdx
    ) external view override returns (DataTypes.UserVaultInfo[] memory) {
        if (fromIdx == 0 && toIdx == 0) {
            toIdx = state.users.length;
        }
        DataTypes.UserVaultInfo[] memory usersVaultInfo = new DataTypes.UserVaultInfo[](
            toIdx - fromIdx
        );
        uint256 count;
        for (uint256 i = fromIdx; i < toIdx; i++) {
            DataTypes.UserVault memory userVault = state.userVaults[state.users[i]];
            usersVaultInfo[count++] = DataTypes.UserVaultInfo({
                user: state.users[i],
                tokenX: userVault.tokenX,
                tokenY: userVault.tokenY
            });
        }
        return usersVaultInfo;
    }

    function userCount() external view returns (uint256) {
        return state.users.length;
    }
}
