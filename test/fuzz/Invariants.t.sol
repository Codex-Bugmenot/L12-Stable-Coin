//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();

        //targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_ProtocolMustHaveMoreValueThanTotalSupply() public view {
        // Get the Value of all the Collateral in the protocol and compare it to all the debt (DSC) in the Protocol

        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);
        uint256 totalValue = wethValue + wbtcValue;

        console.log("wethValue: ", wethValue);
        console.log("wbtcValue: ", wbtcValue);
        console.log("totalSupply: ", totalSupply);

        console.log("timesMintIsCalled: ", handler.timesMintIsCalled());

        assert(totalValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        uint256 amount = 1 ether;
        dsce.getAccountCollatetalValue(msg.sender);
        dsce.getAccountInformation(msg.sender);
        dsce.getCollateralBalanceOfUser(msg.sender, weth);
        dsce.getCollateralTokens();
        dsce.getCollateralTokenPriceFeed(weth);
        dsce.getHealthFactor(msg.sender);
        dsce.getTokenAmountFromUSd(weth, amount);
        dsce.getUsdValue(weth, amount);
        
    }
}
