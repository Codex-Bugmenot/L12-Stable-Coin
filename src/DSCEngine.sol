//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/**
 * @title  DSCEngine
 * @author Codex-BugMeNot
 *
 * The System is Designed to be as minimal as possible and have the tokens maintain a 1 token == $1 peg.
 * This Stable Coin has the properties:
 *  - Exogenous Collateral
 *  - Dollar Pegged
 *  - Algorithimically Stable
 *
 * It is similar to DAI if DAI has no governance , no fees and was only backed by wETH and wBTC
 *
 * Our DSC should always be "OverCollateralized". At no point , the value of all collateral should be <= the $ backed value of all the DSC
 *
 * @notice This Contract is the core of the DSC system , It handles all the logic for mining and redeeming DSC, as well depositing & withdrawing collateral.
 * @notice This Contract is VERY loosely based on MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ////////////////////////////////
    /////     Errors       ////////
    //////////////////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////////
    ///   Type     //////
    ////////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////////////////
    ///   State Variables      ///////
    /////////////////////////////////

    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus is given to liquidators

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscToMint) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////////
    /////     Events       ////////
    //////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    ///////////////////////////////////
    ///     Modifiers       //////////
    /////////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////////////////////
    ///     Functions      ///////////
    /////////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////////////
    ///     External Functions      ///
    //////////////////////////////////

    /**
     * @notice This Function will Deposit Collateral and Mint DSC in one Transaction
     * @param  tokenCollateralAddress The address of the token to deposit as a collateral
     * @param  amountCollateral the amount of the collateral to deposit
     * @param  amountDscToMint the amount of DSC to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Follows CEI (checks,Effects,Interactions)
     * @param tokenCollateralAddress The address of the token to deposit as a collateral
     * @param amountCollateral the amount of the collateral to deposit
     *
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /**
     *
     * @param tokenCollateralAddress The Collateral to redeem
     * @param amountCollateral The amount of Collateral to Deposit
     * @param amountDscToBurn  The amount of DSC to burn
     * @notice This function burns DSC and redeems Underlying Collateral in one Transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }

    // In order to Redeem collateral
    //1.health factor should be greater than 1 after collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Follows CEI (checks,Effects,Interactions)
     * @param amountDscToMint The amount of DSC to mint
     * @notice They must Have Collateral Value more than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // if we do start nearing undercollateralization , we need some one to liquidate positions

    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <-- DSC isnt worth $1 (price of collateral dropped from $100 to $20)

    // $75 ETH backing $50 DSC (price of collateral dropped from $100 to $75)
    // Liquidator takes 75$ backing and burns off the $50 DSC

    // If someone is almost undercollateralized we will pay you to liquidate them!

    /**
     * @param collateral The ERC20 collateral address to liquidar=te from the user
     * @param user The user who has broken the Health Factor, their _healthFacctor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health Factor
     * @notice You can Partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized , then we wouldnt be able to incentivize the liquidators
     * For Example : if the price of the collateral plummeted before anyone could be liquidated
     *
     * Follows CEI: Checks,Effects and Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //Need to Check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt" and take their Collateral
        // Bad user: $140 ETH, $100 DSC
        // debt to cover = $100
        // $100 if DSC == ??? ETH
        // 0.05 ETH

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSd(collateral, debtToCover);
        // And give them a 10% bonus
        // so we are giving the liquidator $110 ETH and $100 DSC
        // we should implement a feature to liquidate in the event if the protocol is insolvent and sweep extra amounts into a treasury

        // 0.05 ETH * 0.1(10% bonus) = 0.005 ETH ------> getting 0.055ETH;
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        // We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////////////////////
    ///    Private & Internal View Functions    /////
    ////////////////////////////////////////////////

    /**
     * @dev Low-Level Internal Funnction, Do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollatetalValue(user);
    }
    /**
     * returns how close to liquidation a us //Need to Check health factor of the userer is
     * if a user gets below 1 they can get liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        //total Dsc Minter
        //total Collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        if (totalDscMinted <= 0) {
            return 1e18;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1.Check HealthFactor (if they have enough collateral)
        //2. Revert if they don't have enough collateral
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////////////
    ///    Public & External View Functions    /////
    ////////////////////////////////////////////////

    function getTokenAmountFromUSd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Price of ETH (token)

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollatetalValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token,get the amount they have deposited
        // and map it to the price to get the USD value

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //1 ETH = 1000$
        //The required value from CL will be 1000*1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // ((1000 * 1e8 * (1e10)) * 1000 * 1e18)/1e18;
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
