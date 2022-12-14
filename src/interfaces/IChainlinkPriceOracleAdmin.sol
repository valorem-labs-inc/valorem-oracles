// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.13;

import "./IERC20.sol";
import "chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IChainlinkPriceOracleAdmin {
    /**
     * @notice Emitted when a price feed for an ERC20 token is set.
     * @param token The contract address for the ERC20.
     * @param priceFeed The price feed address.
     */
    event PriceFeedSet(address indexed token, address indexed priceFeed);

    /**
     * /////////////// ADMIN FUNCTIONS ///////////////
     */

    /**
     * @notice Sets the oracle contract address.
     * @param token The contract address for the erc20 contract.
     * @param priceFeed The contract address for the chainlink price feed.
     * @return The set token and price feed.
     */
    function setPriceFeed(IERC20 token, AggregatorV3Interface priceFeed) external returns (address, address);
}
