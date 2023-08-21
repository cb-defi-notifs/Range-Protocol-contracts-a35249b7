//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {IiZiSwapPool} from "../../iZiSwap/interfaces/IiZiSwapPool.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";


library DataTypes {
    struct PoolData {
        int24 leftPoint;
        int24 rightPoint;
        int24 pointDelta;
        IiZiSwapPool pool;
        IERC20Upgradeable token0;
        IERC20Upgradeable token1;
    }

    struct VaultData {
        bool inThePosition;
        bool mintStarted;
        address factory;
    }

    struct FeeData {
        uint16 managingFee;
        uint16 performanceFee;
        uint256 managerBalance0;
        uint256 managerBalance1;
    }

    struct UserVault {
        bool exists;
        uint256 token0;
        uint256 token1;
    }

    struct UserVaultData {
        mapping(address => UserVault) userVaults;
        address[] users;
    }

    struct State {
        PoolData poolData;
        uint256[50] emptySlots0;
        VaultData vaultData;
        uint256[50] emptySlots1;
        FeeData feeData;
        uint256[50] emptySlots2;
        UserVault userVault;
        uint256[50] emptySlots3;
    }
}