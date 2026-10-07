// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {MockUsdc} from "../src/MockUsdc.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";
import {LaunchCore} from "../src/LaunchCore.sol";

contract LaunchCoreDeploy is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("ETH_LOCAL_PRIVATE_KEY");
        // uint256 deployerPrivateKey = vm.envUint("ETH_REAL_PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        LaunchCore launchCore = new LaunchCore();

        // 本地网。
        address proxyAddress = 0x88D1aF96098a928eE278f162c1a84f339652f95b;

        LaunchCore proxy = LaunchCore(proxyAddress);
        proxy.upgradeToAndCall(address(launchCore), "");

        console.log("deployer addr = ", deployer);
        console.log("LaunchCore addr = ", address(launchCore));
        console.log("Proxy addr = ", address(proxy));

        vm.stopBroadcast();
    }
}
