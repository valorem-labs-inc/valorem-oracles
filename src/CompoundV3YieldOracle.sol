// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.13;

import "./interfaces/ICompoundV3YieldOracle.sol";
import "./interfaces/IComet.sol";
import "./interfaces/IERC20.sol";
import "./utils/Keep3rV2Job.sol";

contract CompoundV3YieldOracle is ICompoundV3YieldOracle, Keep3rV2Job {
    /**
     * /////////// CONSTANTS ///////////////
     */
    address public constant COMET_USDC_ADDRESS = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address public constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint16 public constant DEFAULT_SNAPSHOT_ARRAY_SIZE = 5;
    uint16 public constant MAXIMUM_SNAPSHOT_ARRAY_SIZE = 3 * 5;

    /**
     * ///////////// STRUCTS /////////////
     */
    /// @dev Used to allow cumulative accounting of the time weighted rate
    struct YieldInfo {
        uint256 prevRate;
        uint256 prevTs;
        uint256 totalDelta;
        uint256 weightedRateAcc;
    }

    /**
     * ///////////// STATE ///////////////
     */

    // token to array index mapping
    mapping(IERC20 => uint16) public tokenToSnapshotWriteIndex;

    mapping(IERC20 => SupplyRateSnapshot[]) public tokenToSnapshotArray;

    mapping(IERC20 => IComet) public tokenAddressToComet;

    IERC20[] public tokenRefreshList;

    mapping(address => uint16) private tokenToTokenRefreshListIndex;

    constructor(address _keep3r) {
        admin = msg.sender;
        setCometAddress(USDC_ADDRESS, COMET_USDC_ADDRESS);
        keep3r = _keep3r;
    }

    /**
     * ////////// IYieldOracle //////////
     */

    /// @notice Computed using a time weighted rate of return
    /// @dev compound III / comet is currently deployed/implemented only on USDC
    /// @inheritdoc IYieldOracle
    function getTokenYield(address token) public view returns (uint256 yield) {
        IERC20 _token = IERC20(token);
        IComet comet = tokenAddressToComet[(_token)];
        if (address(comet) == address(0)) {
            revert CometAddressNotSpecifiedForToken(token);
        }

        SupplyRateSnapshot[] memory snapshots = tokenToSnapshotArray[_token];
        /// write idx will always point at eldest element
        uint16 writeIdx = tokenToSnapshotWriteIndex[_token];
        YieldInfo memory yieldInfo = YieldInfo(snapshots[writeIdx].supplyRate, snapshots[writeIdx].timestamp, 0, 0);

        /// go from writeIdx to end of initialized array
        for (uint256 i = writeIdx; i < snapshots.length; i++) {
            SupplyRateSnapshot memory snapshot = snapshots[i];
            /// break from loop if snapshot is not initialized
            if (snapshot.timestamp == 0) {
                break;
            }
            _updateYieldInfo(yieldInfo, snapshot);
        }

        /// go from 0 to writeIdx - 1
        for (uint256 i = 0; i < writeIdx; i++) {
            SupplyRateSnapshot memory snapshot = snapshots[i];
            _updateYieldInfo(yieldInfo, snapshot);
        }

        return yieldInfo.weightedRateAcc / yieldInfo.totalDelta;
    }

    /// @inheritdoc IYieldOracle
    function scale() public pure returns (uint8) {
        return 18;
    }

    /**
     * //////////// Keep3r ////////////
     */

    function work() external validateAndPayKeeper(msg.sender) {
        _latchYieldForRefreshTokens();
    }

    /**
     * //////////// ICompoundV3YieldOracle //////////////
     */

    /// @inheritdoc ICompoundV3YieldOracle
    function setCometAddress(address baseAssetErc20, address comet) public requiresAdmin returns (address, address) {
        if (baseAssetErc20 == address(0)) {
            revert InvalidTokenAddress();
        }
        if (comet == address(0)) {
            revert InvalidCometAddress();
        }

        _updateTokenRefreshList(baseAssetErc20);

        tokenAddressToComet[IERC20(baseAssetErc20)] = IComet(comet);
        _setCometSnapShotBufferSize(baseAssetErc20, DEFAULT_SNAPSHOT_ARRAY_SIZE);

        emit CometSet(baseAssetErc20, comet);
        return (baseAssetErc20, comet);
    }

    /// @inheritdoc ICompoundV3YieldOracle
    function latchCometRate(address token) external requiresAdmin returns (uint256) {
        return _latchSupplyRate(token);
    }

    /// @inheritdoc ICompoundV3YieldOracle
    function latchRatesForRegisteredTokens() external requiresAdmin {
        _latchYieldForRefreshTokens();
    }

    /// @inheritdoc ICompoundV3YieldOracle
    function getCometSnapshots(address token) public view returns (uint16 idx, SupplyRateSnapshot[] memory snapshots) {
        IERC20 _token = IERC20(token);
        idx = tokenToSnapshotWriteIndex[_token];
        snapshots = tokenToSnapshotArray[_token];
    }

    /// @inheritdoc ICompoundV3YieldOracle
    function setCometSnapshotBufferSize(address token, uint16 newSize) external requiresAdmin returns (uint16) {
        return _setCometSnapShotBufferSize(token, newSize);
    }

    /**
     * /////////// Internal ///////////
     */

    function _setCometSnapShotBufferSize(address token, uint16 newSize) internal returns (uint16) {
        if (newSize > MAXIMUM_SNAPSHOT_ARRAY_SIZE) {
            revert SnapshotArraySizeTooLarge();
        }

        SupplyRateSnapshot[] storage snapshots = tokenToSnapshotArray[IERC20(token)];
        if (newSize <= snapshots.length) {
            return uint16(snapshots.length);
        }

        uint16 currentSz = uint16(snapshots.length);
        // increase array size
        for (uint16 i = 0; i < newSize - currentSz; i++) {
            // add uninitialized snapshot to extend length of array
            snapshots.push(SupplyRateSnapshot(0, 0));
        }

        emit CometSnapshotArraySizeSet(token, newSize);
        return newSize;
    }

    function _latchYieldForRefreshTokens() internal {
        for (uint256 i = 0; i < tokenRefreshList.length; i++) {
            _latchSupplyRate(address(tokenRefreshList[i]));
        }
    }

    function _latchSupplyRate(address token) internal returns (uint256 supplyRate) {
        IComet comet;
        IERC20 _token = IERC20(token);
        uint16 idx = tokenToSnapshotWriteIndex[_token];
        SupplyRateSnapshot[] storage snapshots = tokenToSnapshotArray[_token];
        uint16 idxNext = (idx + 1) % uint16(snapshots.length);

        (supplyRate, comet) = _getSupplyRateYieldForUnderlyingAsset(token);

        // update the cached rate
        snapshots[idx].timestamp = block.timestamp;
        snapshots[idx].supplyRate = supplyRate;
        tokenToSnapshotWriteIndex[_token] = idxNext;

        emit CometRateLatched(token, address(comet), supplyRate);
    }

    function _getSupplyRateYieldForUnderlyingAsset(address token) internal view returns (uint256 yield, IComet comet) {
        comet = tokenAddressToComet[IERC20(token)];
        if (address(comet) == address(0)) {
            revert CometAddressNotSpecifiedForToken(token);
        }

        uint256 utilization = comet.getUtilization();
        uint64 supplyRate = comet.getSupplyRate(utilization);
        yield = uint256(supplyRate);
    }

    function _getWeightedPeriodWeightAndTimeDelta(uint256 prevTs, uint256 prevRate, SupplyRateSnapshot memory snapshot)
        internal
        pure
        returns (uint256 tsDelta, uint256 weightedPeriodRate)
    {
        uint256 curTs = snapshot.timestamp;
        uint256 curRate = snapshot.supplyRate;
        tsDelta = curTs - prevTs;

        uint256 periodRate = (curRate + prevRate) / 2;
        weightedPeriodRate = periodRate * tsDelta;
    }

    function _updateTokenRefreshList(address token) internal {
        // append token if not present in refresh list
        uint16 index = tokenToTokenRefreshListIndex[token];

        // uninitialized
        if (index == 0) {
            tokenRefreshList.push(IERC20(token));
            tokenToTokenRefreshListIndex[token] = uint16(tokenRefreshList.length);
        }
    }

    function _updateYieldInfo(YieldInfo memory yieldInfo, SupplyRateSnapshot memory snapshot) internal pure {
        (uint256 tsDelta, uint256 weightedPeriodRate) =
            _getWeightedPeriodWeightAndTimeDelta(yieldInfo.prevTs, yieldInfo.prevRate, snapshot);

        yieldInfo.totalDelta += tsDelta;
        yieldInfo.weightedRateAcc += weightedPeriodRate;

        yieldInfo.prevTs = snapshot.timestamp;
        yieldInfo.prevRate = snapshot.supplyRate;
    }
}
