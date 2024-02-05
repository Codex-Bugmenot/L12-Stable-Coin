//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    MockV3Aggregator mock;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 1;
    uint256 public constant AMOUNT_DSC_TO_BURN = 1;
    uint256 public constant AMOUNT_COLLATERAL_TO_REDEEM = 1 ether;
    uint256 public constant STARTING_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_BALANCE);
    }

    /////////////////////////////////////////
    /////     Constructor Tests       //////
    ///////////////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////////////////////
    /////     Price Tests       ///////
    //////////////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18

        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;

        // 100 / 2000/ETH  = 0.05 ether

        uint256 expectedAmount = 0.05 ether;
        uint256 actualAmount = dsce.getTokenAmountFromUSd(weth, usdAmount);
        assertEq(expectedAmount, actualAmount);
    }

    ///////////////////////////////////////////////
    /////     Deposit Collateral tests      ///////
    //////////////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUSd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = AMOUNT_DSC_TO_MINT;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUSd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    ///////////////////////////////////////////////
    /////     Redeem Collateral tests      ///////
    //////////////////////////////////////////////

    function testCanRedeemCollateralForDsc() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_DSC_TO_MINT);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL_TO_REDEEM, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUSd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL - AMOUNT_COLLATERAL_TO_REDEEM);
    }

    function testRevertsifRedeemCollateralLessThanZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.startPrank(USER);
    }

    modifier redeemedCollateral() {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL_TO_REDEEM);
        vm.stopPrank();
        _;
    }

    function testCanRedeemCollateralAndGetAccountInfo() public depositedCollateral mintedDsc redeemedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = AMOUNT_DSC_TO_MINT;

        uint256 expectedDepositAmount = dsce.getTokenAmountFromUSd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedDepositAmount, (AMOUNT_COLLATERAL - AMOUNT_COLLATERAL_TO_REDEEM));
    }

    //////////////////////////////////////
    /////     Mint DSC tests      ///////
    ////////////////////////////////////

    modifier mintedDsc() {
        vm.startPrank(USER);
        dsce.mintDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testRevertsIfMintDscIsLessThanZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testCanMintDscAndGetAccountInfo() public depositedCollateral mintedDsc {
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = AMOUNT_DSC_TO_MINT;

        assertEq(expectedTotalDscMinted, totalDscMinted);
    }

    function testMintDscRevertsIfHealthFactorIsBroken() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.mintDsc(AMOUNT_DSC_TO_MINT);
        vm.stopPrank();
    }

    //////////////////////////////////////
    /////     Burn DSC tests      ///////
    ////////////////////////////////////

    modifier burnedDsc() {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_DSC_TO_BURN);
        dsce.burnDsc(AMOUNT_DSC_TO_BURN);
        vm.stopPrank();
        _;
    }

    function testRevertsIfBurnDscLessThanZero() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDscAndGetAccountInfo() public depositedCollateral mintedDsc burnedDsc {
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = AMOUNT_DSC_TO_MINT - AMOUNT_DSC_TO_BURN;
        assertEq(expectedTotalDscMinted, totalDscMinted);
    }

    //////////////////////////////////////
    /////     Liquidate tests      //////
    ////////////////////////////////////

    function testRevertsIfDebtToCoverLessThanZero() public depositedCollateral mintedDsc {
        address USER1 = makeAddr("user1");

        vm.startPrank(USER1);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.liquidate(weth, USER, 0);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorOk() public depositedCollateral mintedDsc {
        address USER1 = makeAddr("user1");

        vm.startPrank(USER1);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, 1);
        vm.stopPrank();
    }

    function testCanLiquidateAUserIfHisHealThFactorisBroken() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(10000 ether);

        vm.stopPrank();

        mock = MockV3Aggregator(ethUsdPriceFeed);
        mock.updateAnswer(1400e8);

        address USER1 = makeAddr("user1");
        ERC20Mock(weth).mint(USER1, STARTING_BALANCE + AMOUNT_COLLATERAL);
        vm.startPrank(USER1);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL + STARTING_BALANCE);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL + STARTING_BALANCE);
        dsce.mintDsc(10000 ether);

        dsc.approve(address(dsce), 10000 ether);
        dsce.liquidate(weth, USER, 10000 ether);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////
    /////     HealthFactor and Account tests      //////
    ///////////////////////////////////////////////////

    function testHealthFactorOfAUser() public depositedCollateral {
        uint256 healthFactor = dsce.getHealthFactor(USER);

        assertEq(healthFactor, 1e18);
    }

    function testCanGetAccountInfo() public depositedCollateral mintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        assertEq(totalDscMinted, AMOUNT_DSC_TO_MINT);
        assertEq(collateralValueInUsd, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
    }

    function testCanGetUsdValueOfAnAmountCollateral() public depositedCollateral {
        uint256 usdValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(usdValue, 20000e18);
    }

    function testCanGetAccountCollateralValue() public depositedCollateral {
        uint256 totalCollateralValueInUsd = dsce.getAccountCollatetalValue(USER);

        assertEq(totalCollateralValueInUsd, 20000e18);
    }
}
