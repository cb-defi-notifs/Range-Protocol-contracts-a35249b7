//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {DataTypes} from "./libraries/DataTypes.sol";

/**
 * @notice RangeProtocolVaultStorage a storage contract for RangeProtocolVault
 */
abstract contract RangeProtocolVaultStorage {
    DataTypes.State internal state;
}
