// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeployDreAaveAdapter } from "../script/aave/DeployDreAaveAdapter.s.sol";
import { dreAaveAdapter } from "../contracts/dreAaveAdapter.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { AaveV3PoolMock } from "../contracts/mocks/AaveV3PoolMock.sol";

/**
 * @title DeployDreAaveAdapterTest
 * @notice Tests the dreAaveAdapter deploy script logic.
 */
contract DeployDreAaveAdapterTest is Test, DeployDreAaveAdapter {
    function test_DeployDreAaveAdapter() public {
        vm.chainId(84532);
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 aUsdc = new MockERC20("aUSDC", "aUSDC", 6);
        AaveV3PoolMock pool = new AaveV3PoolMock(address(usdc), address(aUsdc));
        address vault = makeAddr("vault");
        address admin = makeAddr("admin");
        address upgrader = makeAddr("upgrader");
        address manager = makeAddr("manager");

        dreAaveAdapter adapter = _deployDreAaveAdapter(
            address(pool),
            address(usdc),
            vault,
            admin,
            upgrader,
            manager
        );
        address proxyAddr = address(adapter);

        assertGt(proxyAddr.code.length, 0, "proxy should have code");
        assertEq(adapter.aavePool(), address(pool));
        assertEq(adapter.usdc(), address(usdc));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.aUsdc(), address(aUsdc), "aUsdc should be set from pool getReserveData");
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin), "admin should have DEFAULT_ADMIN_ROLE");
        assertTrue(adapter.hasRole(adapter.UPGRADER_ROLE(), upgrader), "upgrader should have UPGRADER_ROLE");
        assertEq(adapter.dreUSDManager(), manager, "dreUSDManager should be set to manager");
    }
}
