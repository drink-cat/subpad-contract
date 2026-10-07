// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {MockUsdc} from "../src/MockUsdc.sol";
// import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";

contract MockUsdcDeploy is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("ETH_LOCAL_PRIVATE_KEY");
        // uint256 deployerPrivateKey = vm.envUint("ETH_REAL_PRIVATE_KEY");

        // 必须用这个地址，当做owner。 否则UUPS升级会失败。
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        MockUsdc mockUSDC = new MockUsdc();

        console.log("deployer addr = ", deployer);
        console.log("MockUsdc addr = ", address(mockUSDC));

        vm.stopBroadcast();
    }
}
