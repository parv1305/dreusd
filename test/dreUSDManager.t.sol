// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockERC20Permit} from "../contracts/mocks/MockERC20Permit.sol";
import {DreUSDMock} from "../contracts/mocks/DreUSDMock.sol";
import {ERC4626Mock} from "../contracts/mocks/ERC4626Mock.sol";
import {DreUSDOracleMock} from "../contracts/mocks/DreUSDOracleMock.sol";
import {WithdrawalNFTMock} from "../contracts/mocks/WithdrawalNFTMock.sol";
import {AaveV3AdapterMock} from "../contracts/mocks/AaveV3AdapterMock.sol";
import {SanctionsListMock} from "../contracts/mocks/SanctionsListMock.sol";
import {dreRewardsDistributorMock} from "../contracts/mocks/dreRewardsDistributorMock.sol";
import {dreUSDManager} from "../contracts/dreUSDManager.sol";
import {IdreUSDManager} from "../contracts/interfaces/IdreUSDManager.sol";
import {IdreUSD} from "../contracts/interfaces/IdreUSD.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IWithdrawalNFT} from "../contracts/interfaces/IWithdrawalNFT.sol";
import {SanctionsListWhitelistWrapper} from "../contracts/whitelist/SanctionsListWhitelistWrapper.sol";

contract dreUSDManagerHarness is dreUSDManager {
    constructor(
        address _dreUSD,
        address _dreUSDs,
        address _usdc,
        address _oracle,
        address _expressWithdrawalNFT,
        address _withdrawalNFT
    ) dreUSDManager(_dreUSD, _dreUSDs, _usdc, _oracle, _expressWithdrawalNFT, _withdrawalNFT) {}

    function exposed_convertToDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) external pure returns (uint256) {
        return _convertToDecimals(amount, fromDecimals, toDecimals);
    }
}

/**
 * @title dreUSDManagerTest
 * @dev Comprehensive test suite for dreUSDManager contract
 */
contract dreUSDManagerTest is Test {
    dreUSDManager public manager;
    dreUSDManager public implementation;
    ERC1967Proxy public proxy;
    
    DreUSDMock public dreUSD;
    ERC4626Mock public dreUSDs;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockERC20Permit public usdcPermit;
    DreUSDOracleMock public oracle;
    SanctionsListMock public sanctionsList;
    WithdrawalNFTMock public expressNFT;
    WithdrawalNFTMock public withdrawalNFT;
    AaveV3AdapterMock public vaultAdapter;
    dreRewardsDistributorMock public rewardsDistributor;

    address public defaultAdmin;
    address public moderator;
    address public withdrawalConfig;
    address public pauser;
    address public keeper;
    address public partner;
    address public treasury;
    address public upgrader;
    address public user1;
    address public user2;
    address public poorUser;
    address public custodian;
    address public expressFeeRecipient;
    address public expressFillerPayback;
    /// @notice Deposit custodian (receives stablecoin from mint flows)
    address public depositCustodian;
    
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant EXPRESS_OPERATOR_ROLE = keccak256("EXPRESS_OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant WITHDRAWAL_CONFIG_ROLE = keccak256("WITHDRAWAL_CONFIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    uint256 public constant INITIAL_USER_BALANCE = 100000 ether;
    uint256 public constant EXPRESS_MAX_LIMIT = 10_000_000e6; // 10M USDC
    uint256 public constant EXPRESS_FEE_BPS = 50; // 0.5%
    
    uint256 public custodianPrivateKey;
    uint256 public user1PrivateKey;
    
    event Minted(address indexed receiver, address asset, uint256 amountIn, uint256 dreUsdOut);
    event MintedFrom(address indexed from, address indexed receiver, address asset, uint256 amountIn, uint256 dreUsdOut);
    event MintAndStake(address indexed receiver, address asset, uint256 amountIn, uint256 sharesOut, uint256 dreUSD);
    event MintRewards(bytes32 indexed mintRef, address indexed receiver, uint256 usdAmount, uint256 dreUSDAmount, address signer);
    event StablecoinAdded(address indexed token);
    event StablecoinRemoved(address indexed token);
    event ExpressWithdrawalRequested(address indexed user, uint256 indexed tokenId, uint256 dreUSDAmount, uint256 usdcAmount, uint256 feeAmount);
    event WithdrawalRequested(address indexed user, uint256 indexed tokenId, uint256 dreUSDAmount, uint256 usdcAmount);
    event ExpressLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event ExpressAvailableUpdated(uint256 oldAvailable, uint256 newAvailable);
    event ExpressFeeUpdated(uint256 oldFee, uint256 newFee);
    event ExpressFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event WithdrawalFilled(uint256 indexed tokenId, address indexed user, uint256 usdcAmount, address indexed filler);
    event WithdrawalSanctioned(uint256 indexed tokenId, address indexed account);
    event ExpressWithdrawalFilled(uint256 indexed tokenId, address indexed user, uint256 usdcAmount, address indexed filler);
    event ExpressFeeCollected(address indexed recipient, uint256 amount);
    event CustodianAdded(address indexed custodian);
    event CustodianRemoved(address indexed custodian);
    event DailyFiatMintUpdated(uint256 indexed day, uint256 newTotal);

    error EnforcedPause();

    function setUp() public {
        _deployContracts();
        _setupAddresses();
        _deployManager();
        _setupRoles();
        _configureManager();
        _configureOracle();
        _fundUsers();
    }
    
    function _deployContracts() internal {
        dreUSD = new DreUSDMock();
        dreUSDs = new ERC4626Mock(address(dreUSD));
        usdc = new MockERC20("USDC", "USDC", 6);
        usdcPermit = new MockERC20Permit("USDC Permit", "USDCP", 6);
        usdt = new MockERC20("USDT", "USDT", 6);
        oracle = new DreUSDOracleMock();
        sanctionsList = new SanctionsListMock();
        expressNFT = new WithdrawalNFTMock();
        withdrawalNFT = new WithdrawalNFTMock();
        vaultAdapter = new AaveV3AdapterMock(address(usdc), address(this));
        rewardsDistributor = new dreRewardsDistributorMock(address(dreUSD), makeAddr("rewardsVault"));
    }
    
    function _setupAddresses() internal {
        defaultAdmin = makeAddr("defaultAdmin");
        moderator = makeAddr("moderator");
        withdrawalConfig = makeAddr("withdrawalConfig");
        pauser = makeAddr("pauser");
        keeper = makeAddr("keeper");
        partner = makeAddr("partner");
        treasury = makeAddr("treasury");
        upgrader = makeAddr("upgrader");
        user1PrivateKey = 0x1;
        user1 = vm.addr(user1PrivateKey);
        user2 = makeAddr("user2");
        expressFeeRecipient = makeAddr("expressFeeRecipient");
        expressFillerPayback = makeAddr("expressFillerPayback");
        custodianPrivateKey = 0x1234;
        custodian = vm.addr(custodianPrivateKey);
        depositCustodian = makeAddr("depositCustodian");
    }
    
    function _deployManager() internal {
        implementation = new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        bytes memory initData = abi.encodeWithSelector(
            dreUSDManager.initialize.selector,
            expressFillerPayback,
            expressFeeRecipient,
            roles
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        manager = dreUSDManager(address(proxy));
        dreUSDs.setRewardsDistributor(address(rewardsDistributor));
        vm.startPrank(defaultAdmin);
        dreUSD.grantRole(dreUSD.MANAGER_ROLE(), address(manager));
        // Wire canonical sanctions list onto dreUSD so that dreUSDManager
        // and other components read a single shared source of truth.
        dreUSD.setSanctionsList(address(sanctionsList));
        vm.stopPrank();
    }
    
    function _setupRoles() internal {
        vm.startPrank(defaultAdmin);
        manager.grantRole(MODERATOR_ROLE, moderator);
        manager.grantRole(WITHDRAWAL_CONFIG_ROLE, moderator);
        manager.grantRole(KEEPER_ROLE, keeper);
        manager.grantRole(EXPRESS_OPERATOR_ROLE, partner);
        manager.grantRole(TREASURY_ROLE, treasury);
        manager.grantRole(UPGRADER_ROLE, upgrader);
        manager.grantRole(PAUSER_ROLE, moderator); // Grant PAUSER_ROLE to moderator for pause tests
        vm.stopPrank();
    }
    
    function _configureManager() internal {
        vm.startPrank(moderator);
        manager.updateVault(depositCustodian);
        manager.updateCustodianList(custodian, true);
        // expressPaybackAddress already set in initialize; no-op call would revert
        manager.updateAllowedList(address(usdc), true);
        manager.updateAllowedList(address(usdt), true);
        manager.updateAllowedList(address(usdcPermit), true);
        vm.stopPrank();
    }
    
    function _configureOracle() internal {
        oracle.setPriceDecimals(address(usdc), 8);
        oracle.setPriceDecimals(address(usdt), 8);
        oracle.setPriceDecimals(address(dreUSD), 8);
        oracle.setPriceDecimals(address(usdcPermit), 8);
    }
    
    function _fundUsers() internal {
        poorUser = makeAddr("poorUser");
        usdc.mint(user1, INITIAL_USER_BALANCE);
        usdt.mint(user1, INITIAL_USER_BALANCE);
        usdc.mint(user2, INITIAL_USER_BALANCE);
        usdcPermit.mint(user1, INITIAL_USER_BALANCE);
        vm.prank(user1);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(user1);
        usdt.approve(address(manager), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(manager), type(uint256).max);
        usdc.mint(address(manager), 1000000e6);
    }
    
    // ============ Initialization Tests ============
    
    function test_Initialize() public  {
        assertEq(manager.dreUSD(), address(dreUSD));
        assertEq(manager.dreUSDs(), address(dreUSDs));
        assertEq(manager.usdc(), address(usdc));
        assertEq(manager.oracle(), address(oracle));
        assertEq(manager.expressWithdrawalNFT(), address(expressNFT));
        assertEq(manager.withdrawalNFT(), address(withdrawalNFT));
        assertEq(manager.dreRewardsDistributor(), address(rewardsDistributor));
        assertEq(manager.expressPaybackAddress(), expressFillerPayback);
        assertEq(manager.expressFeeRecipient(), expressFeeRecipient);
        assertEq(manager.expressWithdrawalMaxLimit(), EXPRESS_MAX_LIMIT);
        assertEq(manager.expressWithdrawalAvailable(), EXPRESS_MAX_LIMIT);
        assertEq(manager.expressWithdrawalFeeBps(), EXPRESS_FEE_BPS);
        assertEq(manager.withdrawalWaitingTime(), 7 days);
        assertTrue(manager.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(manager.hasRole(UPGRADER_ROLE, upgrader));
        assertTrue(manager.hasRole(MODERATOR_ROLE, moderator));
        assertTrue(manager.hasRole(WITHDRAWAL_CONFIG_ROLE, withdrawalConfig));
        assertTrue(manager.hasRole(PAUSER_ROLE, pauser));
        assertTrue(manager.hasRole(KEEPER_ROLE, keeper));
        assertTrue(manager.hasRole(EXPRESS_OPERATOR_ROLE, partner));
        assertTrue(manager.hasRole(TREASURY_ROLE, treasury));
    }

    function test_Initialize_RevertIf_AlreadyInitialized() public {
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        vm.expectRevert();
        manager.initialize(
            expressFillerPayback,
            expressFeeRecipient,
            roles
        );
    }

    function test_Initialize_RevertIf_DefaultAdminIsZeroAddress() public {
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: address(0),
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        bytes memory initData = abi.encodeWithSelector(
            dreUSDManager.initialize.selector,
            expressFillerPayback,
            expressFeeRecipient,
            roles
        );
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_ExpressPaybackAddressIsZeroAddress() public {
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        bytes memory initData = abi.encodeWithSelector(
            dreUSDManager.initialize.selector,
            address(0),
            expressFeeRecipient,
            roles
        );
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_ExpressFeeRecipientIsZeroAddress() public {
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        bytes memory initData = abi.encodeWithSelector(
            dreUSDManager.initialize.selector,
            expressFillerPayback,
            address(0),
            roles
        );
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
    
    // ============ Configuration Tests ============
    
    // Sanctions list is now managed solely on dreUSD; dreUSDManager
    // always reads the canonical list from the token.
    
    function test_Constructor_RevertIf_OracleZero() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(0),
            address(expressNFT),
            address(withdrawalNFT)
        );
    }

    function test_Constructor_RevertIf_DreUSDZero() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new dreUSDManager(
            address(0),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
    }

    function test_Constructor_RevertIf_DreUSDsZero() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new dreUSDManager(
            address(dreUSD),
            address(0),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
    }

    function test_Constructor_RevertIf_UsdcZero() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(0),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
    }

    function test_Constructor_RevertIf_ExpressWithdrawalNFTZero() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(0),
            address(withdrawalNFT)
        );
    }

    function test_Constructor_RevertIf_WithdrawalNFTZero() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(0)
        );
    }

    function test_UpdateVault() public {
        address newCustodianVault = makeAddr("newCustodianVault");
        
        vm.prank(moderator);
        manager.updateVault(newCustodianVault);
        
        assertEq(manager.custodianVault(), newCustodianVault);
    }
    
    function test_UpdateVault_RevertIf_ZeroAddress() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.updateVault(address(0));
    }

    function test_UpdateVault_RevertIf_SameValue() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.SameVault.selector);
        manager.updateVault(depositCustodian);
    }
    
    function test_AddCustodian() public {
        address newCustodian = makeAddr("newCustodian");
        
        vm.prank(moderator);
        vm.expectEmit(true, false, false, false);
        emit CustodianAdded(newCustodian);
        manager.updateCustodianList(newCustodian, true);
        
        assertTrue(manager.custodians(newCustodian));
    }

    function test_AddCustodian_RevertIf_ZeroAddress() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.updateCustodianList(address(0), true);
    }

    function test_AddCustodian_RevertIf_AlreadyAdded() public {
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.CustodianAlreadyAdded.selector, custodian));
        manager.updateCustodianList(custodian, true);
    }

    function test_RemoveCustodian() public {
        vm.prank(moderator);
        vm.expectEmit(true, false, false, false);
        emit CustodianRemoved(custodian);
        manager.updateCustodianList(custodian, false);
        
        assertFalse(manager.custodians(custodian));
    }

    function testRemoveCustodian_RevertIf_NotAllowed() public {
        address notCustodian = makeAddr("notCustodian");
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.CustodianNotAllowed.selector, notCustodian));
        manager.updateCustodianList(notCustodian, false);
    }
    
    function test_SetDailyFiatMintCap() public {
        uint256 newCap = 20_000_000_00; // 20M USD (2 decimals)

        vm.prank(moderator);
        manager.setDailyFiatMintCap(newCap);

        assertEq(manager.dailyFiatMintCapUsd(), newCap);
    }

    function test_setDailyFiatMintCap_AllowsZero() public {
        vm.prank(moderator);
        manager.setDailyFiatMintCap(5000_00);
        vm.prank(moderator);
        manager.setDailyFiatMintCap(0);
        assertEq(manager.dailyFiatMintCapUsd(), 0);
    }

    function test_setDailyFiatMintCap_RevertIf_ExceedsMaxCap() public {
        uint256 maxCap = manager.MAX_DAILY_FIAT_MINT_CAP_USD();
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.DailyFiatMintCapTooHigh.selector, maxCap + 1, maxCap));
        manager.setDailyFiatMintCap(maxCap + 1);
    }

    function test_setDailyFiatMintCap_AllowsMaxCap() public {
        uint256 maxCap = manager.MAX_DAILY_FIAT_MINT_CAP_USD();
        vm.prank(moderator);
        manager.setDailyFiatMintCap(maxCap);
        assertEq(manager.dailyFiatMintCapUsd(), maxCap);
    }

    function test_setDailyFiatMintCap_RevertIf_SameValue() public {
        vm.prank(moderator);
        manager.setDailyFiatMintCap(5000_00);
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.SameDailyFiatMintCap.selector);
        manager.setDailyFiatMintCap(5000_00);
    }

    function test_MintFromUsd_RevertIf_CapIsZero() public {
        // Set cap to non-zero then to 0 to disable fiat mints (no-op revert if already 0)
        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);
        vm.prank(moderator);
        manager.setDailyFiatMintCap(0);
        
        // Try to mint - should revert because cap is 0
        bytes32 mintRef = keccak256("test-mint-ref-zero-cap");
        uint256 usdAmount = 1000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.DailyFiatMintCapExceeded.selector, usdAmount, 0));
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
    }

    function test_DreRewardsDistributor_ReadFromVault() public  {
        assertEq(manager.dreRewardsDistributor(), address(rewardsDistributor));
    }

    // ============ Stablecoin Management Tests ============
    
    function test_AddStablecoin() public {
        MockERC20 newStablecoin = new MockERC20("DAI", "DAI", 18);
        
        vm.prank(moderator);
        vm.expectEmit(true, false, false, false);
        emit StablecoinAdded(address(newStablecoin));
        manager.updateAllowedList(address(newStablecoin), true);
        
        assertTrue(manager.allowed(address(newStablecoin)));
    }
    
    function test_AddStablecoin_RevertIf_ZeroAddress() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.updateAllowedList(address(0), true);
    }
    
    function test_AddStablecoin_RevertIf_AlreadyAllowed() public {
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.StablecoinAlreadyAllowed.selector, address(usdc)));
        manager.updateAllowedList(address(usdc), true);
    }
    
    function test_RemoveStablecoin() public {
        vm.prank(moderator);
        vm.expectEmit(true, false, false, false);
        emit StablecoinRemoved(address(usdc));
        manager.updateAllowedList(address(usdc), false);
        
        assertFalse(manager.allowed(address(usdc)));
    }
    
    function test_RemoveStablecoin_RevertIf_NotAllowed() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.StablecoinNotAllowed.selector, address(newToken)));
        manager.updateAllowedList(address(newToken), false);
    }
    
    // ============ mint with permit tests ============

    function test_Mint_WithPermit() public {
        // Fund the user and set oracle
        uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 10 * 1e8);
        
        // Create permit signature using helper
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);
        
        uint256 balanceBefore = dreUSD.balanceOf(user1);
        // Mint with permit (no prior approval needed)
        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit Minted(address(user1), address(usdcPermit), amount, 10e18);
        manager.mint(address(usdcPermit), amount, 10e18, deadline, permitSig);

        uint256 balanceAfter = dreUSD.balanceOf(user1);

        assertEq(balanceAfter, balanceBefore + 10e18);
        assertEq(usdcPermit.balanceOf(user1), INITIAL_USER_BALANCE - amount);
        assertEq(usdcPermit.allowance(user1, address(manager)), 0);
    }

    /// @dev _executePermit skips permit when allowance is already >= amount (prevents nonce consumption / front-run).
    function test_Mint_WithPermit_AllowanceAlreadyGiven_SkipsPermit() public {
        uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 10 * 1e8);

        // Give allowance before calling mint (simulates prior approve or front-runner having used permit)
        vm.prank(user1);
        usdcPermit.approve(address(manager), amount);

        uint256 nonceBefore = IERC20Permit(address(usdcPermit)).nonces(user1);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);

        uint256 balanceBefore = dreUSD.balanceOf(user1);
        vm.prank(user1);
        manager.mint(address(usdcPermit), amount, 10e18, deadline, permitSig);

        assertEq(dreUSD.balanceOf(user1), balanceBefore + 10e18);
        assertEq(usdcPermit.balanceOf(user1), INITIAL_USER_BALANCE - amount);
        // Allowance was used by transferFrom, so it's 0 after mint
        assertEq(usdcPermit.allowance(user1, address(manager)), 0);
        // Permit was skipped: nonce unchanged (proves _executePermit early-returned)
        assertEq(IERC20Permit(address(usdcPermit)).nonces(user1), nonceBefore);
    }

    function test_Mint_WithPermit_RevertIf_InvalidSignature() public {
        uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 10 * 1e8);
        
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), poorUser, amount, deadline);
        vm.prank(user1);
        vm.expectRevert();
        manager.mint(address(usdcPermit), amount, 10e18, deadline, permitSig);
    }

    function test_Mint_WithPermit_RevertIf_ZeroAmount() public {
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.mint(address(usdcPermit), 0, 1e18, block.timestamp, "");
    }
    
    function test_Mint_RevertIf_CustodianNotSet() public {
        // Deploy a manager and configure oracle + stablecoin but do NOT set custodian
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        dreUSDManager newManager = dreUSDManager(address(new ERC1967Proxy(address(implementation), abi.encodeWithSelector(dreUSDManager.initialize.selector, expressFillerPayback, expressFeeRecipient, roles))));
        vm.prank(defaultAdmin);
        dreUSD.grantRole(dreUSD.MANAGER_ROLE(), address(newManager));
        vm.prank(defaultAdmin);
        newManager.grantRole(MODERATOR_ROLE, moderator);
        vm.startPrank(moderator);
        newManager.updateAllowedList(address(usdc), true);
        // Do NOT set custodian vault - mint should revert
        vm.stopPrank();
        oracle.setUsdValue(address(usdc), 10e8);
        usdc.mint(user1, 100e6);
        vm.prank(user1);
        usdc.approve(address(newManager), 100e6);
        vm.prank(user1);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        newManager.mint(address(usdc), 10e6, 9e18, block.timestamp + 1 days);
    }
    
    function test_Mint_WithPermit_RevertIf_StablecoinNotAllowed() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.StablecoinNotAllowed.selector, address(newToken)));
        manager.mint(address(newToken), 10e18, 10e18, block.timestamp, "");
    }

    function test_Mint_WithPermit_RevertIf_OrderExpired0() public {
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.OrderExpired.selector, block.timestamp - 1, block.timestamp));
        manager.mint(address(usdcPermit), 10e6, 10e18, block.timestamp - 1, "");
    }

    function test_Mint_WithPermit_RevertIf_SlippageExceeded() public {
        uint256 amount = 1000e6;
        uint256 minAmountOut = 10000e18; // Very high minimum
        
        // Set oracle to return less than expected
        oracle.setUsdValue(address(usdcPermit), 100e8);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);

        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SlippageExceeded.selector, minAmountOut, 100e18));
        manager.mint(address(usdcPermit), amount, minAmountOut, deadline, permitSig);
    }

    // ============ mintFrom tests ============

    function test_MintFrom() public {
        uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 20 * 1e8); // 20 USD for 10 usdcPermit
        
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);
        // receiver must equal from; user1 authorizes mint to self
        bytes memory authorizeSig = _createAuthorizeSig(user1PrivateKey, user1, user1, address(usdcPermit), amount, 10e18, deadline);
        
        vm.prank(user2);
        vm.expectEmit(true, true, false, false);
        emit MintedFrom(address(user1), address(user1), address(usdcPermit), amount, 10e18);
        manager.mintFrom(address(user1), address(usdcPermit), amount, address(user1), 10e18, deadline, permitSig, authorizeSig);

        assertEq(dreUSD.balanceOf(user1), 20e18);
        assertEq(usdcPermit.balanceOf(user1), INITIAL_USER_BALANCE - amount);
        assertEq(usdcPermit.allowance(user1, address(manager)), 0);
    }

    function test_MintFrom_RevertIf_ZeroAmount() public {
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.mintFrom(user1, address(usdcPermit), 0, poorUser, 1e18, block.timestamp + 1 days, "", "");
    }
    
    function test_MintFrom_RevertIf_ZeroFrom() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.mintFrom(address(0), address(usdcPermit), 10e6, poorUser, 10e18, block.timestamp + 1 days, "", "");
    }
    
    function test_MintFrom_RevertIf_ZeroReceiver() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.mintFrom(user1, address(usdcPermit), 10e6, address(0), 10e18, block.timestamp + 1 days, "", "");
    }
    
    function test_MintFrom_RevertIf_StablecoinNotAllowed() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.StablecoinNotAllowed.selector, address(newToken)));
        manager.mintFrom(user1, address(newToken), 10e18, poorUser, 10e18, block.timestamp + 1 days, "", "");
    }
    
    function test_MintFrom_RevertIf_OrderExpired() public {
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.OrderExpired.selector, block.timestamp - 1, block.timestamp));
        manager.mintFrom(user1, address(usdcPermit), 10e6, poorUser, 10e18, block.timestamp - 1, "", "");
    }

    function test_MintFrom_RevertIf_SlippageExceeded() public {
        uint256 amount = 10e6;
        uint256 minAmountOut = 10e18;
        oracle.setUsdValue(address(usdcPermit), 9 * 1e8); // return less than expected

        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);
        bytes memory authorizeSig = _createAuthorizeSig(user1PrivateKey, user1, user1, address(usdcPermit), amount, minAmountOut, deadline);
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SlippageExceeded.selector, minAmountOut, 9e18));
        manager.mintFrom(address(user1), address(usdcPermit), amount, address(user1), minAmountOut, deadline, permitSig, authorizeSig);
    }

    function test_MintFrom_RevertIf_InvalidAuthorizeSignature() public {
        uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 20 * 1e8); // 20 USD for 10 usdcPermit
        
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);
        
        // Create authorize signature with wrong private key (custodianPrivateKey instead of user1PrivateKey)
        // This will cause the signer to not match 'from' (user1)
        bytes memory authorizeSig = _createAuthorizeSig(custodianPrivateKey, user1, user1, address(usdcPermit), amount, 10e18, deadline);
        
        vm.prank(user2);
        vm.expectRevert(IdreUSDManager.InvalidMintFromSignature.selector);
        manager.mintFrom(address(user1), address(usdcPermit), amount, address(user1), 10e18, deadline, permitSig, authorizeSig);
    }

    // ============ mint with previously approved tests ============
    
    function test_Mint_WithApproval() public {
        uint256 amount = 1000e6; // 1000 USDC
        uint256 minAmountOut = 990e18; // Allow some slippage
        uint256 deadline = block.timestamp + 1 days;
        
        // Set oracle to return 1:1
        oracle.setUsdValue(address(usdc), amount * 1e12); // Convert 6 decimals to 18
        
        uint256 balanceBefore = dreUSD.balanceOf(user1);
        
        vm.prank(user1);
        manager.mint(address(usdc), amount, minAmountOut, deadline);
        
        assertGt(dreUSD.balanceOf(user1), balanceBefore);
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE - amount);
    }
    
    function test_Mint_RevertIf_StablecoinNotAllowed() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.StablecoinNotAllowed.selector, address(newToken)));
        manager.mint(address(newToken), 1000e18, 990e18, block.timestamp + 1 days);
    }
    
    function test_Mint_RevertIf_OrderExpired() public {
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.OrderExpired.selector, block.timestamp - 1, block.timestamp));
        manager.mint(address(usdc), 1000e6, 990e18, block.timestamp - 1);
    }
    
    function test_Mint_RevertIf_SlippageExceeded() public {
        uint256 amount = 1000e6;
        uint256 minAmountOut = 10000e18; // Very high minimum
        
        // Set oracle to return less than expected
        oracle.setUsdValue(address(usdc), 100e8);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SlippageExceeded.selector, minAmountOut, 100e18));
        manager.mint(address(usdc), amount, minAmountOut, block.timestamp + 1 days);
    }

    function test_Mint_RevertIf_ZeroAmount() public {
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.mint(address(usdc), 0, 990e18, block.timestamp + 1 days);
    }

    function test_Mint_AllFunctions_RevertIf_ZeroCustodianVault() public {
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        dreUSDManager newManager = dreUSDManager(address(new ERC1967Proxy(address(implementation), abi.encodeWithSelector(dreUSDManager.initialize.selector, expressFillerPayback, expressFeeRecipient, roles))));
        vm.startPrank(defaultAdmin);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        newManager.mint(address(usdc), 10e18, 10e18, block.timestamp + 1 days);

        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        newManager.mintFrom(user1, address(usdc), 10e18, user1, 10e18, block.timestamp + 1 days, "", "");

        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        newManager.mintAndStake(address(usdc), 10e18, user1, 10e18, 1, block.timestamp + 1 days, "");

        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        newManager.mint(address(usdc), 10e18, 10e18, block.timestamp + 1 days, "");
        vm.stopPrank();
    }

    // ============ mintAndStake tests ============
    
    function test_MintAndStake() public {
        uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 10 * 1e8);
        
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);
        uint256 sharesBefore = dreUSDs.balanceOf(user1);
        uint256 preview = dreUSDs.previewDeposit(10e18);
        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit MintAndStake(address(user1), address(usdcPermit), amount, 10e18, 10e18);
        manager.mintAndStake(address(usdcPermit), amount, user1, 10e18, 10e18, deadline, permitSig);

        assertGt(dreUSDs.balanceOf(user1), sharesBefore);
        assertEq(dreUSD.balanceOf(address(manager)), 0); // Should be 0 after deposit
        assertEq(dreUSD.balanceOf(user1), 0);
        assertEq(usdcPermit.balanceOf(user1), INITIAL_USER_BALANCE - amount);
        assertEq(preview, dreUSDs.balanceOf(user1));
    }

    function test_MintAndStake_RevertIf_ZeroAmount() public {
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.mintAndStake(address(usdcPermit), 0, user1, 10e18, 1, block.timestamp + 1 days, "");
    }

    function test_MintAndStake_RevertIf_ZeroReceiver() public {
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.mintAndStake(address(usdcPermit), 10e6, address(0), 10e18, 1, block.timestamp + 1 days, "");
    }

    function test_MintAndStake_RevertIf_StablecoinNotAllowed() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.StablecoinNotAllowed.selector, address(newToken)));
        manager.mintAndStake(address(newToken), 10e6, user1, 10e18, 1, block.timestamp + 1 days, "");
    }

    function test_MintAndStake_RevertIf_OrderExpired() public {
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.OrderExpired.selector, block.timestamp - 1, block.timestamp));
        manager.mintAndStake(address(usdcPermit), 10e6, user1, 10e18, 1, block.timestamp - 1, "");
    }

    function test_MintAndStake_RevertIf_SlippageExceeded() public {
         uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 9 * 1e8);
        
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SlippageExceeded.selector, 10e18, 9e18));
        manager.mintAndStake(address(usdcPermit), amount, user1, 10e18, 1, deadline, permitSig);
    }

    function test_MintAndStake_RevertIf_SharesSlippageExceeded() public {
        uint256 amount = 10e6;
        oracle.setUsdValue(address(usdcPermit), 10 * 1e8);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory permitSig = _createPermitSignature(user1PrivateKey, address(usdcPermit), user1, amount, deadline);
        uint256 previewShares = dreUSDs.previewDeposit(10e18);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SlippageExceeded.selector, previewShares + 1, previewShares));
        manager.mintAndStake(address(usdcPermit), amount, user1, 10e18, previewShares + 1, deadline, permitSig);
    }

    function testMintAndStake_RevertIf_SanctionedSender() public {
        vm.prank(moderator);
        sanctionsList.setSanctioned(user1, true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        manager.mintAndStake(address(usdcPermit), 10e6, user1, 10e18, 1, block.timestamp + 1 days, "");
    }

    function testMintAndStake_RevertIf_FrozenSender() public {
        vm.prank(moderator);
        dreUSD.freeze(user1);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        manager.mintAndStake(address(usdcPermit), 10e6, user1, 10e18, 1, block.timestamp + 1 days, "");
    }

    function testMintAndStake_RevertIf_SanctionedReceiver() public {
        vm.prank(moderator);
        sanctionsList.setSanctioned(user2, true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        manager.mintAndStake(address(usdcPermit), 10e6, user2, 10e18, 1, block.timestamp + 1 days, "");
    }
    
    // ============ mintFromUsd tests ============
    
    function test_MintFromUsd() public {
        bytes32 mintRef = keccak256("test-mint-ref");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        
        uint256 balanceBefore = dreUSD.balanceOf(user1);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);
        
        vm.prank(keeper);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
        
        assertGt(dreUSD.balanceOf(user1), balanceBefore);
        assertTrue(manager.usedMintRefs(mintRef));
    }
    
    function test_MintFromUsd_RevertIf_InvalidSignature() public {
        bytes32 mintRef = keccak256("test-mint-ref-2");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        uint256 wrongKey = 0x5678;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);
        
        vm.prank(keeper);
        vm.expectRevert(IdreUSDManager.InvalidCustodianSignature.selector);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
    }
    
    function test_MintFromUsd_RevertIf_MintRefAlreadyUsed() public {
        bytes32 mintRef = keccak256("test-mint-ref-3");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 maxCap = manager.MAX_DAILY_FIAT_MINT_CAP_USD();
        vm.prank(moderator);
        manager.setDailyFiatMintCap(maxCap);

        vm.prank(keeper);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
        
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.MintRefAlreadyUsed.selector, mintRef));
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
    }
    
    function test_MintFromUsd_RevertIf_InvalidChainId() public {
        bytes32 mintRef = keccak256("test-mint-ref-chainid");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        uint256 wrongChainId = block.chainid + 1;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, wrongChainId, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.InvalidChainId.selector, block.chainid, wrongChainId));
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, wrongChainId),
            sig
        );
    }
    
    function test_MintFromUsd_RevertIf_DailyFiatMintCapExceeded() public {
        // Set a daily cap
        vm.prank(moderator);
        manager.setDailyFiatMintCap(5000_00); // 5000 USD (2 decimals)
        
        // First mint within cap
        bytes32 mintRef1 = keccak256("test-mint-ref-cap-1");
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash1 = keccak256(abi.encode(mintRef1, user1, 3000_00, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash1 = MessageHashUtils.toEthSignedMessageHash(structHash1);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(custodianPrivateKey, ethSignedHash1);
        
        vm.prank(keeper);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef1, user1, 3000_00, validUntil, block.chainid),
            abi.encodePacked(r1, s1, v1)
        );
        
        // Try to mint more than the remaining cap
        bytes32 mintRef2 = keccak256("test-mint-ref-cap-2");
        bytes32 structHash2 = keccak256(abi.encode(mintRef2, user1, 2500_00, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash2 = MessageHashUtils.toEthSignedMessageHash(structHash2);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(custodianPrivateKey, ethSignedHash2);
        
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.DailyFiatMintCapExceeded.selector, 5500_00, 5000_00));
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef2, user1, 2500_00, validUntil, block.chainid),
            abi.encodePacked(r2, s2, v2)
        );
    }

    function test_MintFromUsd_RevertIf_ZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(keccak256("test"), user1, 0, block.timestamp + 1 days, block.chainid),
            ""
        );
    }

    function test_MintFromUsd_RevertIf_ZeroReceiver() public {
        vm.prank(keeper);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(keccak256("test"), address(0), 100_00, block.timestamp + 1 days, block.chainid),
            ""
        );
    }

    function test_MintFromUsd_RevertIf_MintExpired() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.MintExpired.selector, block.timestamp - 1));
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(keccak256("test"), user1, 100_00, block.timestamp - 1, block.chainid),
            ""
        );
    }

    /// @dev mintFromUsd must not accept dreRewardsDistributor as receiver; use mintRewards for that.
    function test_MintFromUsd_RevertIf_ReceiverIsDreRewardsDistributor() public {
        bytes32 mintRef = keccak256("test-mint-from-usd-receiver-distributor");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.InvalidReceiver.selector, address(rewardsDistributor)));
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid),
            sig
        );
    }
    
    // ============ mintRewards tests ============
    
    function test_MintRewards() public {
        bytes32 mintRef = keccak256("test-mint-rewards-ref");
        uint256 usdAmount = 10000_00; // $10000 (2 decimals)
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);

        uint256 distributorBalanceBefore = dreUSD.balanceOf(address(rewardsDistributor));

        vm.prank(keeper);
        vm.expectEmit(true, true, false, true);
        emit MintRewards(mintRef, address(rewardsDistributor), usdAmount, 10000e18, custodian);
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid),
            sig
        );

        assertEq(dreUSD.balanceOf(address(rewardsDistributor)), distributorBalanceBefore + 10000e18);
        assertTrue(manager.usedMintRefs(mintRef));
    }
    
    function test_MintRewards_RevertIf_ZeroAmount() public {
        bytes32 mintRef = keccak256("test-mint-rewards-zero");
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), 0, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(keeper);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), 0, validUntil, block.chainid),
            sig
        );
    }
    
    function test_MintRewards_RevertIf_ZeroDistributor() public {
        bytes32 mintRef = keccak256("test-mint-rewards-zero-dist");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(0), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.InvalidReceiver.selector, address(0)));
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(0), usdAmount, validUntil, block.chainid),
            sig
        );
    }

    function test_MintRewards_RevertIf_DreRewardsDistributorNotSet() public {
        bytes32 mintRef = keccak256("test-mint-rewards-dist-not-set");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);
        dreUSDs.setRewardsDistributor(address(0));
        assertEq(manager.dreRewardsDistributor(), address(0));

        vm.prank(keeper);
        vm.expectRevert(IdreUSDManager.DreRewardsDistributorNotSet.selector);
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid),
            sig
        );
    }

    function test_MintRewards_RevertIf_InvalidReceiver() public {
        address wrongReceiver = makeAddr("wrongReceiver");
        bytes32 mintRef = keccak256("test-mint-rewards-invalid-receiver");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, wrongReceiver, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.InvalidReceiver.selector, wrongReceiver));
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, wrongReceiver, usdAmount, validUntil, block.chainid),
            sig
        );
    }

    function test_MintRewards_RevertIf_MintExpired() public {
        bytes32 mintRef = keccak256("test-mint-rewards-expired");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp - 1;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.MintExpired.selector, validUntil));
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid),
            sig
        );
    }

    function test_MintRewards_RevertIf_InvalidCustodianSignature() public {
        bytes32 mintRef = keccak256("test-mint-rewards-bad-sig");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        uint256 wrongKey = 0x5678;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);

        vm.prank(keeper);
        vm.expectRevert(IdreUSDManager.InvalidCustodianSignature.selector);
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid),
            sig
        );
    }
    
    function test_MintRewards_CallsAddRewards() public {
        bytes32 mintRef = keccak256("test-mint-rewards-addrewards");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);

        vm.prank(keeper);
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid),
            sig
        );

        assertTrue(rewardsDistributor.addRewardsCalled(), "addRewards should have been called");
        assertEq(rewardsDistributor.addRewardsCallCount(), 1, "addRewards should have been called once");
    }
    
    function test_MintRewards_RevertIf_Paused() public {
        bytes32 mintRef = keccak256("test-mint-rewards-paused");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(10000_00);
        vm.prank(moderator);
        manager.pause();

        vm.prank(keeper);
        vm.expectRevert(EnforcedPause.selector);
        manager.mintRewards(
            IdreUSDManager.FiatMint(mintRef, address(rewardsDistributor), usdAmount, validUntil, block.chainid),
            sig
        );
    }
    
    // ============ requestWithdrawal tests ============
    
    function test_RequestWithdrawal() public {
        // First mint some dreUSD
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), 1000 * 1e8);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 500e18;
        uint256 minUsdcAmount = 490e6;
        uint256 deadline = block.timestamp + 1 days;
        
        // usdc amount to return
        oracle.setTokenAmount(address(usdc), 500e6);
        
        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit WithdrawalRequested(user1, 1, dreUSDAmount, 500e6);
        uint256 tokenId = manager.requestWithdrawal(dreUSDAmount, minUsdcAmount, deadline);
        
        assertEq(tokenId, 1);
        assertEq(dreUSD.balanceOf(user1), 1000e18 - dreUSDAmount);

        IWithdrawalNFT.Position memory position = withdrawalNFT.getPosition(tokenId);
        assertEq(position.user, user1);
        assertEq(position.usdcAmount, 500e6);
        assertEq(position.createdAt, block.timestamp);
    }

    function test_RequestWithdrawal_RevertIf_Sanctioned() public {
        vm.prank(moderator);
        sanctionsList.setSanctioned(user1, true);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SanctionedAddress.selector, user1));
        manager.requestWithdrawal(1000e18, 990e6, block.timestamp + 1 days);
    }
    
    function test_RequestWithdrawal_RevertIf_SlippageExceeded() public {
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), 1000 * 1e8);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 500e18;
        // Set oracle to return less than expected
        oracle.setTokenAmount(address(usdc), 400e6); // Less than minUsdcAmount
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SlippageExceeded.selector, 490e6, 400e6));
        manager.requestWithdrawal(dreUSDAmount, 490e6, block.timestamp + 1 days);
    }

    function test_RequestWithdrawal_RevertIf_OrderExpired() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.OrderExpired.selector, block.timestamp - 1, block.timestamp));
        manager.requestWithdrawal(1000e18, 990e6, block.timestamp - 1);
    }

    function test_RequestWithdrawal_RevertIf_ZeroAmount() public {
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.requestWithdrawal(0, 990e6, block.timestamp + 1 days);
    }

    // ============ requestExpressWithdrawal tests ============

    function test_RequestExpressWithdrawal() public {
        // First mint some dreUSD
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), 1000 * 1e8);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 100e18;
        uint256 minUsdcAmount = 99e6;
        uint256 deadline = block.timestamp + 1 days;
        
        // Set oracle to return 100e6 USDC for 100e18 dreUSD
        oracle.setTokenAmount(address(usdc), 100e6);
        
        // Verify oracle returns correct value
        uint256 expectedUsdcAmount = oracle.getTokenAmount(address(usdc), dreUSDAmount);
        assertEq(expectedUsdcAmount, 100e6, "Oracle should return 100e6 USDC");
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ExpressWithdrawalRequested(user1, 1, 100e6, 99_500_000, 500_000);
        emit ExpressAvailableUpdated(EXPRESS_MAX_LIMIT, EXPRESS_MAX_LIMIT - 100e6);
        uint256 expressTokenId = manager.requestExpressWithdrawal(dreUSDAmount, minUsdcAmount, deadline);
        
        assertGt(expressTokenId, 0);
        assertEq(manager.expressWithdrawalAvailable(), EXPRESS_MAX_LIMIT - 100e6);
        assertEq(manager.expressFillerDebt(), 0);
        assertEq(manager.expressWithdrawalFees(1), 0.5e6);
        assertEq(dreUSD.balanceOf(user1), 1000e18 - dreUSDAmount);
    }

    /// @dev When totalUsdcAmount > expressWithdrawalAvailable, reverts with NoExpressAvailable (all-or-nothing; no partial fill).
    function test_RequestExpressWithdrawal_RevertIf_ExpressAmountExceedsAvailable() public {
        // First mint enough dreUSD and consume most of express limit so only 100 USDC remains
        uint256 mintAmount = 10_000_100e6;
        oracle.setUsdValue(address(usdc), 10_000_100 * 1e8);
        usdc.mint(user1, mintAmount);
        vm.prank(user1);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 10_000_000e18, block.timestamp + 1 days);

        uint256 firstWithdrawalDreUSD = 9_999_900e18;
        oracle.setTokenAmount(address(usdc), 9_999_900e6);
        uint256 firstWithdrawalFee = (9_999_900e6 * EXPRESS_FEE_BPS) / 10_000;
        uint256 firstWithdrawalUserReceives = 9_999_900e6 - firstWithdrawalFee;
        vm.prank(user1);
        manager.requestExpressWithdrawal(firstWithdrawalDreUSD, firstWithdrawalUserReceives - 1e6, block.timestamp + 1 days);

        assertEq(manager.expressWithdrawalAvailable(), 100e6, "Available should be 100 USDC after first withdrawal");

        // Request 200e18 dreUSD → oracle returns 200e6 USDC; only 100e6 available → revert, no burn
        uint256 dreUSDAmount = 200e18;
        oracle.setTokenAmount(address(usdc), 200e6);
        uint256 dreUSDBalanceBefore = dreUSD.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(IdreUSDManager.NoExpressAvailable.selector);
        manager.requestExpressWithdrawal(dreUSDAmount, 90e6, block.timestamp + 1 days);

        assertEq(dreUSD.balanceOf(user1), dreUSDBalanceBefore, "No dreUSD should be burned on revert");
        assertEq(manager.expressWithdrawalAvailable(), 100e6, "Available unchanged after revert");
    }
    
    function test_RequestExpressWithdrawal_RevertIf_NoExpressAvailable() public {
        // First, fund user1 with enough USDC to mint 10M dreUSD
        usdc.mint(user1, 10_000_000e6);
        vm.prank(user1);
        usdc.approve(address(manager), type(uint256).max);
        
        // Mint 10M dreUSD - oracle should return 10M USD in 8 decimals
        uint256 mintAmount = 10_000_000e6;
        oracle.setUsdValue(address(usdc), 10_000_000e8); // 10M USD in 8 decimals
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 9_900_000e18, block.timestamp + 1 days);
        
        // Make an express withdrawal that uses up the entire limit (10M USDC)
        uint256 dreUSDAmount = 10_000_000e18;
        oracle.setTokenAmount(address(usdc), 10_000_000e6);
        oracle.setTokenAmount(address(dreUSD), 10_000_000e18);
        
        vm.prank(user1);
        manager.requestExpressWithdrawal(dreUSDAmount, 9_900_000e6, block.timestamp + 1 days);
        
        // Verify express available is now 0
        assertEq(manager.expressWithdrawalAvailable(), 0);
        
        // Try to make another express withdrawal - should fail
        // First mint more dreUSD for the second withdrawal attempt
        usdc.mint(user1, 1000e6);
        oracle.setUsdValue(address(usdc), 1000e8); // 1000 USD in 8 decimals
        vm.prank(user1);
        manager.mint(address(usdc), 1000e6, 990e18, block.timestamp + 1 days);
        
        oracle.setTokenAmount(address(usdc), 100e6);
        oracle.setTokenAmount(address(dreUSD), 100e18);
        
        vm.prank(user1);
        vm.expectRevert(IdreUSDManager.NoExpressAvailable.selector);
        manager.requestExpressWithdrawal(100e18, 99e6, block.timestamp + 1 days);
    }

    function test_RequestExpressWithdrawal_RevertIf_FeeRecipientNotSet() public {
        // Note: expressFeeRecipient is now required in initialize, so this scenario is no longer possible.
        // The test_Initialize_RevertIf_ExpressFeeRecipientIsZeroAddress test covers the validation.
        // This test verifies that initialize properly requires expressFeeRecipient to be non-zero.
        dreUSDManager newImpl = new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        bytes memory initData = abi.encodeWithSelector(
            dreUSDManager.initialize.selector,
            expressFillerPayback,
            address(0), // expressFeeRecipient zero causes initialize to revert
            roles
        );
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    /// @dev Slippage is checked against totalUsdcAmount (gross from oracle), not net-after-fee.
    function test_RequestExpressWithdrawal_RevertIf_SlippageExceeded() public {
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1000 * 1e8);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);

        uint256 dreUSDAmount = 100e18;
        uint256 minUsdcAmount = 99e6;
        oracle.setTokenAmount(address(usdc), 90e6); // totalUsdcAmount < minUsdcAmount

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.SlippageExceeded.selector, minUsdcAmount, 90e6));
        manager.requestExpressWithdrawal(dreUSDAmount, minUsdcAmount, block.timestamp + 1 days);
    }

    /// @dev When totalUsdcAmount exceeds expressWithdrawalAvailable, reverts with NoExpressAvailable (no partial fill).
    function test_RequestExpressWithdrawal_RevertIf_NoExpressAvailable_WhenRequestExceedsAvailable() public {
        uint256 mintAmount = 10_000_000e6;
        oracle.setUsdValue(address(usdc), 10_000_000e8);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 9_900_000e18, block.timestamp + 1 days);

        // First withdrawal: leave only 50e6 USDC express available
        uint256 firstUsdcAmount = EXPRESS_MAX_LIMIT - 50e6;
        oracle.setTokenAmount(address(usdc), firstUsdcAmount);
        uint256 firstWithdrawalFee = (firstUsdcAmount * EXPRESS_FEE_BPS) / 10_000;
        uint256 firstWithdrawalUserReceives = firstUsdcAmount - firstWithdrawalFee;
        vm.prank(user1);
        manager.requestExpressWithdrawal(firstUsdcAmount * 1e12, firstWithdrawalUserReceives - 1e6, block.timestamp + 1 days);

        assertEq(manager.expressWithdrawalAvailable(), 50e6, "50 USDC express limit left");

        // Request 100e18 dreUSD → 100e6 USDC required; only 50e6 available → NoExpressAvailable
        oracle.setTokenAmount(address(usdc), 100e6);
        vm.prank(user1);
        vm.expectRevert(IdreUSDManager.NoExpressAvailable.selector);
        manager.requestExpressWithdrawal(100e18, 80e6, block.timestamp + 1 days);
    }

    function test_RequestExpressWithdrawal_RevertIf_OrderExpired() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.OrderExpired.selector, block.timestamp - 1, block.timestamp));
        manager.requestExpressWithdrawal(1000e18, 99e6, block.timestamp - 1);
    }

    function test_RequestExpressWithdrawal_RevertIf_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.requestExpressWithdrawal(0, 99e6, block.timestamp + 1 days);
    }
    
    // ============ fillWithdrawal tests ============

    function test_FillWithdrawal() public {
        // Create a withdrawal request
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 500e18;
        oracle.setTokenAmount(address(usdc), 500e6);
        
        vm.prank(user1);
        uint256 tokenId = manager.requestWithdrawal(dreUSDAmount, 490e6, block.timestamp + 1 days);
        
        // Fast forward past waiting time
        vm.warp(block.timestamp + 7 days + 1);
        
        // Fund treasury with USDC
        usdc.mint(treasury, 1000e6);
        vm.prank(treasury);
        usdc.approve(address(manager), type(uint256).max);
        
        uint256 balanceBefore = usdc.balanceOf(user1);
        assertEq(IWithdrawalNFT(withdrawalNFT).positionExists(tokenId), true);
        vm.prank(treasury);
        vm.expectEmit(true, true, false, false);
        emit WithdrawalFilled(tokenId, user1, 500e6, treasury);
        (uint256 filledCount, uint256 totalFilled) = manager.fillWithdrawal(
            _toArray(tokenId),
            false
        );
        
        assertEq(filledCount, 1);
        assertEq(totalFilled, 500e6);
        assertEq(usdc.balanceOf(user1), balanceBefore + 500e6);
        assertEq(usdc.balanceOf(treasury), 1000e6 - 500e6);
        assertEq(IWithdrawalNFT(withdrawalNFT).positionExists(tokenId), false);
    }

    function test_FillWithdrawal_WithVault() public {
        // Create withdrawal
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 500e18;
        oracle.setTokenAmount(address(usdc), 500e6);
        
        vm.prank(user1);
        uint256 tokenId = manager.requestWithdrawal(dreUSDAmount, 490e6, block.timestamp + 1 days);
        
        // Configure vault adapter
        vm.prank(moderator);
        manager.updateVaultAdapter(address(vaultAdapter));
        
        vaultAdapter.setAvailableBalance(1000e6);
        usdc.mint(address(vaultAdapter), 1000e6);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        uint256 balanceBefore = usdc.balanceOf(user1);
        
        vm.prank(treasury);
        vm.expectEmit(true, true, false, false);
        emit WithdrawalFilled(tokenId, user1, 500e6, address(vaultAdapter));
        (uint256 filledCount, uint256 totalFilled) = manager.fillWithdrawal(
            _toArray(tokenId),
            true // use vault
        );
        
        assertEq(filledCount, 1);
        assertEq(totalFilled, 500e6);
        assertEq(usdc.balanceOf(user1), balanceBefore + 500e6);
    }

    function test_FillWithdrawal_Reverts() public {
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 500e18;
        oracle.setTokenAmount(address(usdc), 500e6);

        uint256 maxCap = manager.MAX_DAILY_FIAT_MINT_CAP_USD();
        vm.prank(moderator);
        manager.setDailyFiatMintCap(maxCap);

        vm.prank(user1);
        uint256 tokenId = manager.requestWithdrawal(dreUSDAmount, 490e6, block.timestamp + 1 days);

        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.fillWithdrawal(new uint256[](0), false);

        // Don't fast forward - should revert
        usdc.mint(treasury, 1000e6);
        vm.prank(treasury);
        usdc.approve(address(manager), type(uint256).max);
        
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.NotReady.selector);
        manager.fillWithdrawal(_toArray(tokenId), false);
        
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.MissingPosition.selector);
        manager.fillWithdrawal(_toArray(2), false);

        vm.warp(block.timestamp + 7 days + 1);

        // Blocked (sanctioned) owner: fillWithdrawal skips and emits WithdrawalSanctioned, does not revert
        vm.prank(moderator);
        sanctionsList.setSanctioned(user1, true);

        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        vm.prank(treasury);
        vm.expectEmit(true, true, false, false);
        emit WithdrawalSanctioned(tokenId, user1);
        (uint256 filledCount, uint256 totalFilled) = manager.fillWithdrawal(_toArray(tokenId), false);
        assertEq(filledCount, 0, "sanctioned owner: nothing filled");
        assertEq(totalFilled, 0, "sanctioned owner: no amount filled");
        assertEq(IWithdrawalNFT(withdrawalNFT).positionExists(tokenId), true, "NFT not burned when skipped");
        assertEq(usdc.balanceOf(treasury), treasuryBalanceBefore, "treasury unchanged when skipped");

        vm.prank(moderator);
        sanctionsList.removeSanctioned(user1);

        // burn the USDC from the treasury
        usdc.burn(treasury, 1000e6);
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.NoBalance.selector);
        manager.fillWithdrawal(_toArray(tokenId), false);

        vm.prank(moderator);
        manager.updateVaultAdapter(address(vaultAdapter));
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.NoBalance.selector);
        manager.fillWithdrawal(_toArray(tokenId), true);

        // test fillWithdrawal with no adaper
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        dreUSDManager newManager = dreUSDManager(address(new ERC1967Proxy(address(implementation), abi.encodeWithSelector(dreUSDManager.initialize.selector, expressFillerPayback, expressFeeRecipient, roles))));
        vm.prank(defaultAdmin);
        newManager.grantRole(TREASURY_ROLE, treasury);
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        newManager.fillWithdrawal(_toArray(tokenId), true);
    }

    function test_FillWithdrawal_RevertIf_Paused() public {
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        uint256 dreUSDAmount = 500e18;
        oracle.setTokenAmount(address(usdc), 500e6);
        vm.prank(user1);
        uint256 tokenId = manager.requestWithdrawal(dreUSDAmount, 490e6, block.timestamp + 1 days);
        vm.warp(block.timestamp + 7 days + 1);
        usdc.mint(treasury, 1000e6);
        vm.prank(treasury);
        usdc.approve(address(manager), type(uint256).max);

        vm.prank(moderator);
        manager.pause();
        vm.prank(treasury);
        vm.expectRevert(EnforcedPause.selector);
        manager.fillWithdrawal(_toArray(tokenId), false);
    }

    // ============ fillExpressWithdrawals tests ============
    
    function test_FillExpressWithdrawals() public {
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 100e18;
        oracle.setTokenAmount(address(usdc), 100e6);
        oracle.setTokenAmount(address(dreUSD), 100e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(dreUSDAmount, 99e6, block.timestamp + 1 days);
        
        uint256 userAmount = 99.5e6;
        uint256 feeAmount = 0.5e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        
        uint256 balanceBefore = usdc.balanceOf(user1);
        uint256 feeBefore = usdc.balanceOf(expressFeeRecipient);
        
        vm.prank(partner);
        vm.expectEmit(true, true, false, false);
        emit ExpressFeeCollected(expressFeeRecipient, feeAmount );
        vm.expectEmit(true, true, false, true);
        emit ExpressWithdrawalFilled(expressTokenId, user1, userAmount, partner);
        (uint256 filledCount,) = manager.fillExpressWithdrawals(_toArray(expressTokenId));
        
        assertEq(filledCount, 1);
        assertEq(usdc.balanceOf(user1), balanceBefore + userAmount);
        assertEq(usdc.balanceOf(expressFeeRecipient), feeBefore + feeAmount);
        assertEq(manager.expressWithdrawalFees(expressTokenId), 0);
        assertEq(usdc.balanceOf(partner), 0);
        assertEq(IWithdrawalNFT(expressNFT).positionExists(expressTokenId), false);
    }

    function test_FillExpressWithdrawals_Reverts() public {
        // Set up express withdrawal
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 100e18;
        oracle.setTokenAmount(address(usdc), 100e6);
        oracle.setTokenAmount(address(dreUSD), 100e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(dreUSDAmount, 99e6, block.timestamp + 1 days);
        
        uint256 userAmount = 99.5e6;
        uint256 feeAmount = 0.5e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        
        // Test MissingPosition - non-existent tokenId
        vm.prank(partner);
        vm.expectRevert(IdreUSDManager.MissingPosition.selector);
        manager.fillExpressWithdrawals(_toArray(999));
        
        // Sanctioned owner: fillExpressWithdrawals skips tokenId and emits WithdrawalSanctioned, does not revert
        vm.prank(moderator);
        sanctionsList.setSanctioned(user1, true);

        uint256 partnerBalanceBefore = usdc.balanceOf(partner);
        vm.prank(partner);
        vm.expectEmit(true, true, false, false);
        emit WithdrawalSanctioned(expressTokenId, user1);
        (uint256 filledCount, uint256 totalFilled) = manager.fillExpressWithdrawals(_toArray(expressTokenId));
        assertEq(filledCount, 0, "sanctioned owner: nothing filled");
        assertEq(totalFilled, 0, "sanctioned owner: no amount filled");
        assertEq(IWithdrawalNFT(expressNFT).positionExists(expressTokenId), true, "NFT not burned when skipped");
        assertEq(usdc.balanceOf(partner), partnerBalanceBefore, "partner balance unchanged when skipped");

        vm.prank(moderator);
        sanctionsList.removeSanctioned(user1);
        
        // Test NoBalance - burn USDC from partner
        usdc.burn(partner, userAmount + feeAmount);
        vm.prank(partner);
        vm.expectRevert(IdreUSDManager.NoBalance.selector);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));

        // Test no tokenIds provided
        vm.prank(partner);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.fillExpressWithdrawals(new uint256[](0));
    }

    function test_FillExpressWithdrawals_RevertIf_Paused() public {
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        uint256 dreUSDAmount = 100e18;
        oracle.setTokenAmount(address(usdc), 100e6);
        oracle.setTokenAmount(address(dreUSD), 100e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(dreUSDAmount, 99e6, block.timestamp + 1 days);
        uint256 userAmount = 99.5e6;
        uint256 feeAmount = 0.5e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);

        vm.prank(moderator);
        manager.pause();
        vm.prank(partner);
        vm.expectRevert(EnforcedPause.selector);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));
    }
    
    // ============ payExpressDebt tests ============
    
    function test_PayExpressDebt() public {
        // Create express withdrawal to create debt
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 100e18;
        oracle.setTokenAmount(address(usdc), 100e6);
        oracle.setTokenAmount(address(dreUSD), 100e18);
        
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(dreUSDAmount, 99e6, block.timestamp + 1 days);
        
        assertEq(manager.expressFillerDebt(), 0);
        uint256 availableBefore = manager.expressWithdrawalAvailable();
        uint256 paybackAmount = 50e6;

        // try to payback when no debt
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.PaybackExceedsDebt.selector, paybackAmount, 0));
        manager.payExpressDebt(paybackAmount);

        // fill express withdrawal
        usdc.mint(partner, 1000e6);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(partner);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));

        uint256 debtBefore = manager.expressFillerDebt();
        assertEq(debtBefore, 100e6);
        
        // Fund treasury and approve manager for payback
        usdc.mint(treasury, paybackAmount);
        vm.prank(treasury);
        usdc.approve(address(manager), type(uint256).max);
        
        vm.prank(treasury);
        manager.payExpressDebt(paybackAmount);

        assertEq(manager.expressFillerDebt(), debtBefore - paybackAmount);
        assertEq(manager.expressWithdrawalAvailable(), availableBefore + paybackAmount);
        assertEq(usdc.balanceOf(expressFillerPayback), paybackAmount);
    }

    function test_PayExpressDebt_RevertIf_ExceedsDebt() public {
        // Create express withdrawal
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 100e18;
        oracle.setTokenAmount(address(usdc), 100e6);
        oracle.setTokenAmount(address(dreUSD), 100e18);
        
        vm.prank(user1);
        manager.requestExpressWithdrawal(dreUSDAmount, 99e6, block.timestamp + 1 days);
        
        uint256 debt = manager.expressFillerDebt();
        
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.PaybackExceedsDebt.selector, debt + 1, debt));
        manager.payExpressDebt(debt + 1);
    }
    
    function test_PayExpressDebt_AsTreasury() public {
        // Create express withdrawal and fill it to create debt
        uint256 mintAmount = 1000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 990e18, block.timestamp + 1 days);
        
        uint256 dreUSDAmount = 100e18;
        oracle.setTokenAmount(address(usdc), 100e6);
        oracle.setTokenAmount(address(dreUSD), 100e18);
        
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(dreUSDAmount, 99e6, block.timestamp + 1 days);
        
        // Fill express withdrawal
        uint256 userAmount = 99.5e6;
        uint256 feeAmount = 0.5e6;
        uint256 totalRequired = userAmount + feeAmount;
        usdc.mint(partner, totalRequired);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(partner);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));
        
        uint256 debtBefore = manager.expressFillerDebt();
        assertEq(debtBefore, 100e6);
        uint256 availableBefore = manager.expressWithdrawalAvailable();
        uint256 paybackAmount = 50e6;
        
        // Fund treasury and approve manager for payback
        usdc.mint(treasury, paybackAmount);
        vm.prank(treasury);
        usdc.approve(address(manager), type(uint256).max);
        
        vm.prank(treasury);
        manager.payExpressDebt(paybackAmount);
        
        assertEq(manager.expressFillerDebt(), debtBefore - paybackAmount);
        assertEq(manager.expressWithdrawalAvailable(), availableBefore + paybackAmount);
        assertEq(usdc.balanceOf(expressFillerPayback), paybackAmount);
    }

    /// @dev Reducing limit below current outstanding reverts with ExpressLimitBelowOutstanding.
    function test_UpdateExpressWithdrawal_RevertWhenLimitBelowOutstanding_AfterFullFill() public {
        uint256 mintAmount = 10_000_000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 9_900_000e18, block.timestamp + 1 days);
        uint256 expressAmount = 10_000_000e18;
        oracle.setTokenAmount(address(usdc), 10_000_000e6);
        oracle.setTokenAmount(address(dreUSD), 10_000_000e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(expressAmount, 9_950_000e6, block.timestamp + 1 days);
        uint256 userAmount = 9_950_000e6;
        uint256 feeAmount = 50_000e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(partner);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));
        assertEq(manager.expressWithdrawalAvailable(), 0, "Available exhausted");
        uint256 outstanding = 10_000_000e6;
        uint256 newMaxLimit = 8_000_000e6;
        uint256 feeBps = manager.expressWithdrawalFeeBps();
        address feeRecipient = manager.expressFeeRecipient();
        vm.prank(withdrawalConfig);
        vm.expectRevert(
            abi.encodeWithSelector(
                IdreUSDManager.ExpressLimitBelowOutstanding.selector,
                newMaxLimit,
                outstanding
            )
        );
        manager.updateExpressWithdrawal(newMaxLimit, feeBps, feeRecipient);
    }

    function test_PayExpressDebt_LimitHeadroom() public {
        // Use 8M express, then set limit to 8M so headroom = 8M - 0 = 8M (limit cannot be set below outstanding)
        uint256 mintAmount = 10_000_000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 9_900_000e18, block.timestamp + 1 days);
        uint256 expressAmount = 8_000_000e18;
        oracle.setTokenAmount(address(usdc), 8_000_000e6);
        oracle.setTokenAmount(address(dreUSD), 8_000_000e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(expressAmount, 7_950_000e6, block.timestamp + 1 days);
        uint256 userAmount = 7_960_000e6;
        uint256 feeAmount = 40_000e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(partner);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));
        uint256 newMaxLimit = 8_000_000e6;
        uint256 feeBps = manager.expressWithdrawalFeeBps();
        address feeRecipient = manager.expressFeeRecipient();
        vm.prank(moderator);
        manager.updateExpressWithdrawal(newMaxLimit, feeBps, feeRecipient);
        uint256 finalDebt = manager.expressFillerDebt();
        uint256 finalAvailable = manager.expressWithdrawalAvailable();
        uint256 finalHeadroom = manager.expressWithdrawalMaxLimit() - finalAvailable;
        assertEq(finalDebt, 8_000_000e6);
        assertEq(finalAvailable, 0);
        assertEq(finalHeadroom, 8_000_000e6);

        // Payback more than headroom reverts
        uint256 paybackAttempt = 9_000_000e6;
        usdc.mint(treasury, paybackAttempt);
        vm.prank(treasury);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(IdreUSDManager.PaybackExceedsDebt.selector, paybackAttempt, finalHeadroom)
        );
        manager.payExpressDebt(paybackAttempt);

        // Payback exactly headroom succeeds
        uint256 paybackAmount = finalHeadroom;
        usdc.mint(treasury, paybackAmount);
        vm.prank(treasury);
        manager.payExpressDebt(paybackAmount);
        assertEq(manager.expressFillerDebt(), 0);
        assertEq(manager.expressWithdrawalAvailable(), finalHeadroom);
        assertEq(usdc.balanceOf(expressFillerPayback), paybackAmount);
    }

    function test_PayExpressDebt_RevertIf_ZeroAmount() public {
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.payExpressDebt(0);
    }

    function test_PayExpressDebt_RevertIf_NoPaybackAddressSet() public {
        // Note: expressPaybackAddress is now always set during initialization.
        // This test verifies that paying when there's no debt reverts with PaybackExceedsDebt
        dreUSDManager.RoleAddresses memory roles = dreUSDManager.RoleAddresses({
            defaultAdmin: defaultAdmin,
            upgrader: upgrader,
            moderator: moderator,
            withdrawalConfig: withdrawalConfig,
            pauser: pauser,
            keeper: keeper,
            expressOperator: partner,
            treasury: treasury
        });
        dreUSDManager newManager = dreUSDManager(address(new ERC1967Proxy(address(implementation), abi.encodeWithSelector(dreUSDManager.initialize.selector, expressFillerPayback, expressFeeRecipient, roles))));
        vm.prank(defaultAdmin);
        newManager.grantRole(TREASURY_ROLE, treasury);
        vm.prank(treasury);
        // When there's no debt (expressFillerDebt = 0), trying to pay will revert with PaybackExceedsDebt
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.PaybackExceedsDebt.selector, 100e6, 0));
        newManager.payExpressDebt(100e6);
    }
    
    // ============ View Functions Tests ============
    
    function test_GetExpressAvailable() public  {
        uint256 available = manager.getExpressAvailable();
        assertEq(available, EXPRESS_MAX_LIMIT);
    }
    
    function test_CalculateExpressFee() public  {
        uint256 usdcAmount = 1000e6;
        (uint256 feeAmount, uint256 userReceives) = manager.calculateExpressFee(usdcAmount);
        
        assertEq(feeAmount, 5e6); // 0.5% of 1000 USDC = 5 USDC
        assertEq(userReceives, usdcAmount - feeAmount);
    }
    
    // ============ Internal Function Tests - _convertToDecimals ============
    
    /**
     * @dev Test _convertToDecimals when fromDecimals equals toDecimals
     *      This tests the conversion through mint() -> _mintDreUSD() -> _convertToDecimals()
     */
    function test_ConvertToDecimals_FromEqualsTo() public {
        // Create a token with 18 decimals (same as dreUSD)
        MockERC20 token18 = new MockERC20("TOKEN18", "T18", 18);
        
        // Add token as stablecoin
        vm.prank(moderator);
        manager.updateAllowedList(address(token18), true);
        
        // Set oracle price decimals to 18 (same as dreUSD)
        oracle.setPriceDecimals(address(token18), 18);
        
        // Fund user
        uint256 mintAmount = 1000e18; // 1000 tokens with 18 decimals
        token18.mint(user1, mintAmount);
        
        // Set oracle to return USD value (in 18 decimals)
        uint256 usdValue = 1000e18; // 1000 USD in 18 decimals
        oracle.setUsdValue(address(token18), usdValue);
        
        // Approve and mint
        vm.prank(user1);
        token18.approve(address(manager), mintAmount);
        
        uint256 balanceBefore = dreUSD.balanceOf(user1);
        
        vm.prank(user1);
        manager.mint(address(token18), mintAmount, 990e18, block.timestamp + 1 days);
        
        // Since fromDecimals (18) == toDecimals (18), conversion should be 1:1
        // USD value is 1000e18, so dreUSD minted should be 1000e18
        uint256 dreUSDMinted = dreUSD.balanceOf(user1) - balanceBefore;
        assertEq(dreUSDMinted, 1000e18, "Should mint 1000e18 dreUSD when decimals are equal");
    }
    
    /**
     * @dev Test _convertToDecimals when fromDecimals > toDecimals
     *      This tests the conversion through mint() -> _mintDreUSD() -> _convertToDecimals()
     */
    function test_ConvertToDecimals_FromGreaterThanTo() public {
        // Create a token with 18 decimals (dreUSD also has 18 decimals)
        MockERC20 token18 = new MockERC20("TOKEN18", "T18", 18);
        
        // Add token as stablecoin
        vm.prank(moderator);
        manager.updateAllowedList(address(token18), true);
        
        // Set oracle price decimals to 20 (greater than dreUSD's 18 decimals)
        oracle.setPriceDecimals(address(token18), 20);
        
        // Fund user
        uint256 mintAmount = 1000e18; // 1000 tokens with 18 decimals
        token18.mint(user1, mintAmount);
        
        // Set oracle to return USD value (in 20 decimals)
        // 1000 USD in 20 decimals = 1000 * 10^20
        uint256 usdValue = 1000e20; // 1000 USD in 20 decimals
        oracle.setUsdValue(address(token18), usdValue);
        
        // Approve and mint
        vm.prank(user1);
        token18.approve(address(manager), mintAmount);
        
        uint256 balanceBefore = dreUSD.balanceOf(user1);
        
        vm.prank(user1);
        manager.mint(address(token18), mintAmount, 990e18, block.timestamp + 1 days);
        
        // Since fromDecimals (20) > toDecimals (18), conversion should divide by 10^(20-18) = 10^2
        // USD value is 1000e20, so dreUSD minted should be 1000e20 / 10^2 = 1000e18
        uint256 dreUSDMinted = dreUSD.balanceOf(user1) - balanceBefore;
        assertEq(dreUSDMinted, 1000e18, "Should convert from 20 decimals to 18 decimals correctly");
        
        // Test with a different value to ensure the conversion is correct
        // Mint more tokens to user for second test
        uint256 mintAmount2 = 500e18; // 500 tokens with 18 decimals
        token18.mint(user1, mintAmount2);
        
        uint256 usdValue2 = 500e20; // 500 USD in 20 decimals
        oracle.setUsdValue(address(token18), usdValue2);
        
        vm.prank(user1);
        token18.approve(address(manager), mintAmount2);
        
        uint256 balanceBefore2 = dreUSD.balanceOf(user1);
        vm.prank(user1);
        manager.mint(address(token18), mintAmount2, 490e18, block.timestamp + 1 days);
        
        uint256 dreUSDMinted2 = dreUSD.balanceOf(user1) - balanceBefore2;
        assertEq(dreUSDMinted2, 500e18, "Should convert 500e20 to 500e18 correctly");
    }
    
    /**
     * @dev Test _convertToDecimals when fromDecimals < toDecimals (already tested via mintFromUsd)
     *      This is the common case: price feed has 8 decimals, dreUSD has 18 decimals
     *      Adding this test for completeness
     */
    function test_ConvertToDecimals_FromLessThanTo() public {
        // USDC has 6 decimals, price feed has 8 decimals (default), dreUSD has 18 decimals
        // This tests the fromDecimals < toDecimals path
        
        uint256 amount = 1000e6; // 1000 USDC (6 decimals)
        uint256 usdValue = 1000e8; // 1000 USD in price feed decimals (8 decimals)
        
        oracle.setUsdValue(address(usdc), usdValue);
        
        vm.prank(user1);
        usdc.approve(address(manager), amount);
        
        uint256 balanceBefore = dreUSD.balanceOf(user1);
        
        vm.prank(user1);
        manager.mint(address(usdc), amount, 990e18, block.timestamp + 1 days);
        
        // Since fromDecimals (8) < toDecimals (18), conversion should multiply by 10^(18-8) = 10^10
        // USD value is 1000e8, so dreUSD minted should be 1000e8 * 10^10 = 1000e18
        uint256 dreUSDMinted = dreUSD.balanceOf(user1) - balanceBefore;
        assertEq(dreUSDMinted, 1000e18, "Should convert from 8 decimals to 18 decimals correctly");
    }

    function testFuzz_ConvertToDecimals(uint256 amountRaw, uint256 fromDecimalsRaw, uint256 toDecimalsRaw) public {
        dreUSDManagerHarness harness = new dreUSDManagerHarness(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );

        uint8 fromDecimals = uint8(bound(fromDecimalsRaw, 0, 77));
        uint8 toDecimals = uint8(bound(toDecimalsRaw, 0, 77));

        uint256 amount = amountRaw;
        uint256 expected;

        if (fromDecimals == toDecimals) {
            expected = amount;
        } else if (fromDecimals > toDecimals) {
            uint256 factor = 10 ** (fromDecimals - toDecimals);
            expected = amount / factor;
        } else {
            uint256 factor = 10 ** (toDecimals - fromDecimals);
            amount = bound(amount, 0, type(uint256).max / factor);
            expected = amount * factor;
        }

        assertEq(harness.exposed_convertToDecimals(amount, fromDecimals, toDecimals), expected);
    }
    
    // ============ Admin Functions Tests ============
    
    function test_AdminWithdraw() public {
        uint256 amount = 1000e6;
        usdc.mint(address(manager), amount);
        
        uint256 balanceBefore = usdc.balanceOf(treasury);
        
        vm.prank(treasury);
        manager.adminWithdraw(address(usdc), treasury, amount);
        
        assertEq(usdc.balanceOf(treasury), balanceBefore + amount);
    }
    
    function test_AdminWithdraw_RevertIf_NotTreasury() public {
        vm.expectRevert();
        manager.adminWithdraw(address(usdc), treasury, 1000e6);
    }
    
    function test_AdminWithdraw_RevertIf_ZeroAddress() public {
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.adminWithdraw(address(0), treasury, 1000e6);

        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.adminWithdraw(address(usdc), address(0), 1000e6);
    }

    function test_AdminWithdraw_RevertIf_ZeroAmount() public {
        vm.prank(treasury);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.adminWithdraw(address(usdc), treasury, 0);
    }
    
    // ============ Express Withdrawal Configuration Tests ============
    
    function test_UpdateExpressWithdrawal_MaxLimit() public {
        uint256 newLimit = 20_000_000e6;

        vm.prank(user1);
        vm.expectRevert();
        manager.updateExpressWithdrawal(newLimit, EXPRESS_FEE_BPS, expressFeeRecipient);
        
        vm.prank(moderator);
        manager.updateExpressWithdrawal(newLimit, EXPRESS_FEE_BPS, expressFeeRecipient);
        
        assertEq(manager.expressWithdrawalMaxLimit(), newLimit);
        // With zero utilization, available should equal new limit
        assertEq(manager.expressWithdrawalAvailable(), newLimit, "Available should match new limit when outstanding is 0");
    }

    /// @dev updateExpressWithdrawal emits ExpressLimitUpdated, ExpressAvailableUpdated, ExpressFeeUpdated, ExpressFeeRecipientUpdated in order.
    function test_UpdateExpressWithdrawal_EmitsAllFourEvents() public {
        uint256 newLimit = 5_000_000e6;
        uint256 oldLimit = EXPRESS_MAX_LIMIT;
        uint256 oldAvailable = EXPRESS_MAX_LIMIT;
        uint256 newAvailable = newLimit; // 0 utilization
        uint256 oldFee = EXPRESS_FEE_BPS;
        address oldRecipient = expressFeeRecipient;
        address emitter = address(manager);

        vm.expectEmit(false, false, false, true, emitter);
        emit ExpressLimitUpdated(oldLimit, newLimit);
        vm.expectEmit(false, false, false, true, emitter);
        emit ExpressAvailableUpdated(oldAvailable, newAvailable);
        vm.expectEmit(false, false, false, true, emitter);
        emit ExpressFeeUpdated(oldFee, EXPRESS_FEE_BPS);
        vm.expectEmit(true, true, false, false, emitter);
        emit ExpressFeeRecipientUpdated(oldRecipient, expressFeeRecipient);
        vm.prank(moderator);
        manager.updateExpressWithdrawal(newLimit, EXPRESS_FEE_BPS, expressFeeRecipient);
    }

    /// @dev When maxLimit is reduced with zero utilization, available = maxLimit - 0 = maxLimit.
    function test_UpdateExpressWithdrawal_ReducesAvailableWhenNoUtilization() public {
        assertEq(manager.expressWithdrawalAvailable(), EXPRESS_MAX_LIMIT, "Initial available is full limit");

        uint256 newMaxLimit = 3_000_000e6; // 3M USDC
        vm.prank(moderator);
        manager.updateExpressWithdrawal(newMaxLimit, EXPRESS_FEE_BPS, expressFeeRecipient);

        assertEq(manager.expressWithdrawalMaxLimit(), newMaxLimit);
        assertEq(manager.expressWithdrawalAvailable(), newMaxLimit, "Available = maxLimit - outstanding (0)");
    }

    /// @dev Reverts when new limit is below current outstanding utilization.
    function test_UpdateExpressWithdrawal_RevertIf_MaxLimitBelowOutstanding() public {
        // Create 7M outstanding: request + fill express for 7M
        uint256 mintAmount = 10_000_000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 9_900_000e18, block.timestamp + 1 days);
        uint256 expressAmount = 7_000_000e18;
        oracle.setTokenAmount(address(usdc), 7_000_000e6);
        oracle.setTokenAmount(address(dreUSD), 7_000_000e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(expressAmount, 6_950_000e6, block.timestamp + 1 days);
        uint256 userAmount = 6_965_000e6;
        uint256 feeAmount = 35_000e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(partner);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));
        assertEq(manager.expressWithdrawalAvailable(), 3_000_000e6, "Available = 3M after 7M used");
        uint256 outstanding = EXPRESS_MAX_LIMIT - manager.expressWithdrawalAvailable();
        assertEq(outstanding, 7_000_000e6, "Outstanding = 7M");

        uint256 newLimitBelowOutstanding = 5_000_000e6;
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IdreUSDManager.ExpressLimitBelowOutstanding.selector,
                newLimitBelowOutstanding,
                outstanding
            )
        );
        manager.updateExpressWithdrawal(newLimitBelowOutstanding, EXPRESS_FEE_BPS, expressFeeRecipient);
    }

    /// @dev When limit is increased, available increases by the same amount (utilization preserved).
    function test_UpdateExpressWithdrawal_PreservesUtilization_IncreaseLimit() public {
        // Use 7M: available = 3M, outstanding = 7M
        uint256 mintAmount = 10_000_000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 9_900_000e18, block.timestamp + 1 days);
        uint256 expressAmount = 7_000_000e18;
        oracle.setTokenAmount(address(usdc), 7_000_000e6);
        oracle.setTokenAmount(address(dreUSD), 7_000_000e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(expressAmount, 6_950_000e6, block.timestamp + 1 days);
        uint256 userAmount = 6_965_000e6;
        uint256 feeAmount = 35_000e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(partner);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));
        assertEq(manager.expressWithdrawalAvailable(), 3_000_000e6);
        uint256 newLimit = 20_000_000e6;
        vm.prank(moderator);
        manager.updateExpressWithdrawal(newLimit, EXPRESS_FEE_BPS, expressFeeRecipient);
        assertEq(manager.expressWithdrawalMaxLimit(), newLimit);
        assertEq(manager.expressWithdrawalAvailable(), 13_000_000e6, "Available = 20M - 7M outstanding");
    }

    /// @dev When limit is decreased to above outstanding, available = newLimit - outstanding.
    function test_UpdateExpressWithdrawal_PreservesUtilization_DecreaseLimit() public {
        // Use 7M: available = 3M, outstanding = 7M
        uint256 mintAmount = 10_000_000e6;
        oracle.setUsdValue(address(usdc), mintAmount * 1e12);
        vm.prank(user1);
        manager.mint(address(usdc), mintAmount, 9_900_000e18, block.timestamp + 1 days);
        uint256 expressAmount = 7_000_000e18;
        oracle.setTokenAmount(address(usdc), 7_000_000e6);
        oracle.setTokenAmount(address(dreUSD), 7_000_000e18);
        vm.prank(user1);
        uint256 expressTokenId = manager.requestExpressWithdrawal(expressAmount, 6_950_000e6, block.timestamp + 1 days);
        uint256 userAmount = 6_965_000e6;
        uint256 feeAmount = 35_000e6;
        usdc.mint(partner, userAmount + feeAmount);
        vm.prank(partner);
        usdc.approve(address(manager), type(uint256).max);
        vm.prank(partner);
        manager.fillExpressWithdrawals(_toArray(expressTokenId));
        assertEq(manager.expressWithdrawalAvailable(), 3_000_000e6);
        uint256 newLimit = 8_000_000e6; // >= 7M outstanding
        vm.prank(moderator);
        manager.updateExpressWithdrawal(newLimit, EXPRESS_FEE_BPS, expressFeeRecipient);
        assertEq(manager.expressWithdrawalMaxLimit(), newLimit);
        assertEq(manager.expressWithdrawalAvailable(), 1_000_000e6, "Available = 8M - 7M outstanding");
    }
    
    function test_UpdateExpressWithdrawal_Fee() public {
        uint256 newFee = 100; // 1%

        vm.prank(user1);
        vm.expectRevert();
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, newFee, expressFeeRecipient);
        
        vm.prank(moderator);
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, newFee, expressFeeRecipient);
        
        assertEq(manager.expressWithdrawalFeeBps(), newFee);
    }
    
    function test_UpdateExpressWithdrawal_RevertIf_FeeOverMax() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.InvalidLimit.selector);
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, 501, expressFeeRecipient); // Max is 500 bps (5%)
    }
    
    function test_UpdateExpressWithdrawal_MaxFeeAllowed() public {
        uint256 maxFee = 500; // 5% - maximum allowed
        
        vm.prank(moderator);
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, maxFee, expressFeeRecipient);
        
        assertEq(manager.expressWithdrawalFeeBps(), maxFee);
    }
    
    function test_UpdateExpressWithdrawal_FeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        
        vm.prank(user1);
        vm.expectRevert();
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, EXPRESS_FEE_BPS, newRecipient);

        vm.prank(moderator);
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, EXPRESS_FEE_BPS, newRecipient);
        
        assertEq(manager.expressFeeRecipient(), newRecipient);
    }

    function test_UpdateExpressWithdrawal_RevertIf_ZeroFeeRecipient() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, EXPRESS_FEE_BPS, address(0));
    }
    
    function test_UpdateExpressPaybackAddress() public {
        address newAddress = makeAddr("newExpressPayback");
        
        vm.prank(moderator);
        manager.updateExpressPaybackAddress(newAddress);
        
        assertEq(manager.expressPaybackAddress(), newAddress);
    }

    function test_UpdateExpressPaybackAddress_RevertIf_ZeroAddress() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.updateExpressPaybackAddress(address(0));
    }

    function test_UpdateExpressPaybackAddress_RevertIf_SameValue() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.SameExpressPaybackAddress.selector);
        manager.updateExpressPaybackAddress(expressFillerPayback);
    }

    function test_UpdateExpressWithdrawal_RevertIf_ZeroMaxLimit() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.ZeroAmount.selector);
        manager.updateExpressWithdrawal(0, EXPRESS_FEE_BPS, expressFeeRecipient);
    }

    function test_UpdateExpressWithdrawal_RevertIf_SameConfig() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.SameExpressWithdrawalConfig.selector);
        manager.updateExpressWithdrawal(EXPRESS_MAX_LIMIT, EXPRESS_FEE_BPS, expressFeeRecipient);
    }
    
    // ============ Withdrawal Configuration Tests ============
    
    function test_UpdateWithdrawal_WaitingTime() public {
        uint256 newWaitingTime = 14 days;
        
        vm.prank(user1);
        vm.expectRevert();
        manager.updateWithdrawal(newWaitingTime);

        vm.prank(moderator);
        manager.updateWithdrawal(newWaitingTime);
        
        assertEq(manager.withdrawalWaitingTime(), newWaitingTime);
    }

    function test_UpdateWithdrawal_RevertIf_BelowMin() public {
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(
            IdreUSDManager.InvalidWithdrawalWaitingTime.selector,
            0,
            1 days,
            14 days
        ));
        manager.updateWithdrawal(0);

        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(
            IdreUSDManager.InvalidWithdrawalWaitingTime.selector,
            12 hours,
            1 days,
            14 days
        ));
        manager.updateWithdrawal(12 hours);
    }

    function test_UpdateWithdrawal_RevertIf_AboveMax() public {
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(
            IdreUSDManager.InvalidWithdrawalWaitingTime.selector,
            15 days,
            1 days,
            14 days
        ));
        manager.updateWithdrawal(15 days);
    }

    function test_UpdateWithdrawal_AcceptsBoundaries() public {
        vm.prank(moderator);
        manager.updateWithdrawal(1 days);
        assertEq(manager.withdrawalWaitingTime(), 1 days);

        vm.prank(moderator);
        manager.updateWithdrawal(14 days);
        assertEq(manager.withdrawalWaitingTime(), 14 days);
    }

    function test_UpdateWithdrawal_RevertIf_SameValue() public {
        assertEq(manager.withdrawalWaitingTime(), 7 days);
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.SameWithdrawalWaitingTime.selector);
        manager.updateWithdrawal(7 days);
    }
    
    function test_UpdateVaultAdapter() public {
        AaveV3AdapterMock newAdapter = new AaveV3AdapterMock(address(usdc), address(this));
        
        vm.prank(user1);
        vm.expectRevert();
        manager.updateVaultAdapter(address(newAdapter));

        vm.prank(moderator);
        manager.updateVaultAdapter(address(newAdapter));
        
        assertEq(manager.withdrawalVaultAdapter(), address(newAdapter));
    }

    function test_UpdateVaultAdapter_RevertIf_ZeroAddress() public {
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.ZeroAddress.selector);
        manager.updateVaultAdapter(address(0));
    }

    function test_UpdateVaultAdapter_RevertIf_IncompatibleUsdc() public {
        // Adapter configured for a different token (e.g. USDT) than manager's USDC
        AaveV3AdapterMock wrongAdapter = new AaveV3AdapterMock(address(usdt), address(this));
        vm.prank(withdrawalConfig);
        vm.expectRevert(abi.encodeWithSelector(IdreUSDManager.IncompatibleVaultAdapter.selector, address(wrongAdapter), address(usdc)));
        manager.updateVaultAdapter(address(wrongAdapter));
    }
    
    function test_UpdateVaultAdapter_RevertIf_SameValue() public {
        vm.prank(moderator);
        manager.updateVaultAdapter(address(vaultAdapter));
        vm.prank(moderator);
        vm.expectRevert(IdreUSDManager.SameVaultAdapter.selector);
        manager.updateVaultAdapter(address(vaultAdapter));
    }
    
    // ============ Additional Withdrawal Tests ============

    function test_GetDailyFiatMinted() public {
        assertEq(manager.getDailyFiatMinted(), 0);
        
        bytes32 mintRef = keccak256("mint-ref-daily");
        uint256 usdAmount = 1000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(1000_00);
        
        vm.prank(keeper);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
        
        assertEq(manager.getDailyFiatMinted(), usdAmount);
    }

    function test_DailyFiatMintUpdated_EmitsEvent() public {
        bytes32 mintRef = keccak256("mint-ref-daily-event");
        uint256 usdAmount = 500_00;
        uint256 validUntil = block.timestamp + 1 days;
        uint256 currentDay = block.timestamp / 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(moderator);
        manager.setDailyFiatMintCap(1000_00);

        vm.expectEmit(true, true, false, true);
        emit DailyFiatMintUpdated(currentDay, usdAmount);
        vm.prank(keeper);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
    }
    
    function test_GetExpressFillerDebt() public  {
        uint256 debt = manager.getExpressFillerDebt();
        assertEq(debt, 0);
    }

    // ============ Pausable Tests ============
    
    function test_Mint_RevertIf_Paused() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        
        // Try to mint - should revert
        uint256 amount = 1000e6;
        
        vm.prank(user1);
        vm.expectRevert(EnforcedPause.selector);
        manager.mint(address(usdc), amount, 990e18, block.timestamp + 1 days);
    }
    
    function test_Mint_WithPermit_RevertIf_Paused() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        
        vm.prank(user1);
        vm.expectRevert(EnforcedPause.selector);
        manager.mint(address(usdcPermit), 10e6, 10e18, block.timestamp + 1 days, "");
    }
    
    function test_MintFrom_RevertIf_Paused() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        
        vm.prank(user2);
        vm.expectRevert(EnforcedPause.selector);
        manager.mintFrom(address(user1), address(usdcPermit), 10e6, address(poorUser), 10e18, block.timestamp, "", "");
    }
    
    function test_MintAndStake_RevertIf_Paused() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        
        vm.expectRevert(EnforcedPause.selector);
manager.mintAndStake(address(usdcPermit), 10e6, user1, 10e18, 1, block.timestamp, "");
    }

    function test_MintFromUsd_RevertIf_Paused() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        
        // Try to mintFromUsd - should revert
        bytes32 mintRef = keccak256("test-mint-ref-paused");
        uint256 usdAmount = 10000_00;
        uint256 validUntil = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(mintRef, user1, usdAmount, validUntil, block.chainid, address(manager)));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(custodianPrivateKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        
        uint256 maxCap = manager.MAX_DAILY_FIAT_MINT_CAP_USD();
        vm.prank(moderator);
        manager.setDailyFiatMintCap(maxCap);
        
        vm.prank(keeper);
        vm.expectRevert(EnforcedPause.selector);
        manager.mintFromUsd(
            IdreUSDManager.FiatMint(mintRef, user1, usdAmount, validUntil, block.chainid),
            sig
        );
    }
    
    function test_RequestWithdrawal_RevertIf_Paused() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        
        vm.prank(user1);
        vm.expectRevert(EnforcedPause.selector);
        manager.requestWithdrawal(500e18, 490e6, block.timestamp + 1 days);
    }
    
    function test_RequestExpressWithdrawal_RevertIf_Paused() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        
        vm.prank(user1);
        vm.expectRevert(EnforcedPause.selector);
        manager.requestExpressWithdrawal(100e18, 99e6, block.timestamp + 1 days);
    }

    function test_Unpause_Success() public {
        // Pause the contract
        vm.prank(moderator);
        manager.pause();
        assertTrue(manager.paused());

        // Unpause with PAUSER_ROLE
        vm.prank(moderator);
        manager.unpause();
        assertFalse(manager.paused());
    }

    function test_Unpause_RevertIf_NotPauser() public {
        // Attempt to unpause without PAUSER_ROLE
        vm.prank(user1);
        vm.expectRevert();
        manager.unpause();
    }
    
    // ============ SupportsInterface Tests ============
    
    function test_SupportsInterface_ERC165() public {
        // ERC165 interface ID: 0x01ffc9a7
        assertTrue(manager.supportsInterface(0x01ffc9a7));
    }
    
    function test_SupportsInterface_AccessControl() public  {
        // AccessControl interface ID: 0x7965db0b
        assertTrue(manager.supportsInterface(0x7965db0b));
    }
    
    function test_SupportsInterface_Unsupported() public {
        // Random unsupported interface ID
        assertFalse(manager.supportsInterface(0x12345678));
        // ERC721 interface ID (not supported by dreUSDManager)
        assertFalse(manager.supportsInterface(0x80ac58cd));
    }
    
    // ============ Upgrade Tests ============
    
    function test_Upgrade_Success() public {
        // Create a new implementation (same contract, just a new instance)
        dreUSDManager newImplementation = new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
        
        // Upgrade should succeed when called by UPGRADER_ROLE
        vm.prank(upgrader);
        manager.upgradeToAndCall(address(newImplementation), "");
        
        // Verify the proxy still works - check that state is preserved
        assertEq(manager.dreUSD(), address(dreUSD));
        assertEq(manager.dreUSDs(), address(dreUSDs));
        assertEq(manager.usdc(), address(usdc));
    }
    
    function test_Upgrade_RevertIf_NotUpgrader() public {
        dreUSDManager newImplementation = new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
        
        // Upgrade should revert when called by non-UPGRADER_ROLE
        vm.prank(user1);
        vm.expectRevert();
        manager.upgradeToAndCall(address(newImplementation), "");
    }
    
    function test_Upgrade_RevertIf_DefaultAdminWithoutUpgraderRole() public {
        // Create a new address that has DEFAULT_ADMIN_ROLE but not UPGRADER_ROLE
        address adminWithoutUpgrader = makeAddr("adminWithoutUpgrader");
        
        vm.startPrank(defaultAdmin);
        manager.grantRole(DEFAULT_ADMIN_ROLE, adminWithoutUpgrader);
        // Explicitly do NOT grant UPGRADER_ROLE
        vm.stopPrank();
        
        dreUSDManager newImplementation = new dreUSDManager(
            address(dreUSD),
            address(dreUSDs),
            address(usdc),
            address(oracle),
            address(expressNFT),
            address(withdrawalNFT)
        );
        
        // Even with DEFAULT_ADMIN_ROLE, upgrade should revert without UPGRADER_ROLE
        vm.prank(adminWithoutUpgrader);
        vm.expectRevert();
        manager.upgradeToAndCall(address(newImplementation), "");
    }
    
    // ============ Helper Functions ============
    
    function _toArray(uint256 value) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = value;
        return arr;
    }
    
    function _createPermitSignature(
        uint256 privateKey,
        address token,
        address owner,
        uint256 value,
        uint256 deadline
    ) internal view returns (bytes memory) {
        uint256 nonce = IERC20Permit(token).nonces(owner);
        bytes32 PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 domainSeparator = IERC20Permit(token).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(manager), value, nonce, deadline));
        bytes32 hash = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);
        return abi.encode(deadline, v, r, s);
    }

    /// @dev Creates EIP-712 MintFrom authorize signature; signer must be from (receiver must equal from in mintFrom).
    function _createAuthorizeSig(
        uint256 fromPrivateKey,
        address from,
        address receiver,
        address asset,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = _mintFromDigest(from, receiver, asset, amountIn, minAmountOut, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mintFromDigest(
        address from,
        address receiver,
        address asset,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal view returns (bytes32) {
        uint256 nonce = manager.authNonce(from);
        bytes32 structHash = keccak256(
            abi.encode(
                manager.AUTH_MINTFROM_TYPEHASH(),
                from,
                receiver,
                asset,
                amountIn,
                minAmountOut,
                deadline,
                nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", manager.authDomainSeparator(), structHash));
    }
}
