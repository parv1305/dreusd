// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {dreWithdrawalNFT} from "../contracts/dreWithdrawalNFT.sol";
import {IWithdrawalNFT} from "../contracts/interfaces/IWithdrawalNFT.sol";
import {DreUSDMock} from "../contracts/mocks/DreUSDMock.sol";
import {SanctionsListMock} from "../contracts/mocks/SanctionsListMock.sol";
import {IdreUSD} from "../contracts/interfaces/IdreUSD.sol";

/**
 * @title DreWithdrawalNFTTest
 * @dev Comprehensive test suite for dreWithdrawalNFT contract
 */
contract DreWithdrawalNFTTest is Test {
    dreWithdrawalNFT public nft;
    dreWithdrawalNFT public implementation;
    ERC1967Proxy public proxy;
    DreUSDMock public dreUSD;
    SanctionsListMock public sanctionsList;

    address public defaultAdmin;
    address public manager;
    address public minter;
    address public burner;
    address public upgrader;
    address public user1;
    address public user2;
    address public unauthorized;
    address public sanctionedUser;
    address public frozenUser;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 public constant USDC_AMOUNT_1 = 100_000e6; // 100k USDC
    uint256 public constant USDC_AMOUNT_2 = 50_000e6;  // 50k USDC

    event PositionCreated(
        uint256 indexed tokenId,
        address indexed user,
        uint256 usdcAmount,
        uint256 createdAt
    );
    event PositionFilled(
        uint256 indexed tokenId,
        address indexed user,
        uint256 usdcAmount,
        address indexed filler
    );
    event DreUSDUpdated(address indexed dreUSD);

    function setUp() public {
        _setupAddresses();
        _deployNFT();
    }

    function _setupAddresses() internal {
        defaultAdmin = makeAddr("defaultAdmin");
        manager = makeAddr("manager");
        minter = makeAddr("minter");
        burner = makeAddr("burner");
        upgrader = makeAddr("upgrader");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");
        sanctionedUser = makeAddr("sanctionedUser");
        frozenUser = makeAddr("frozenUser");
    }

    function _deployNFT() internal {
        sanctionsList = new SanctionsListMock();
        dreUSD = new DreUSDMock();
        dreUSD.setSanctionsList(address(sanctionsList));
        implementation = new dreWithdrawalNFT();
        bytes memory initData = abi.encodeWithSelector(
            dreWithdrawalNFT.initialize.selector,
            address(dreUSD),
            "DRE Withdrawal",
            "dreWD",
            defaultAdmin,
            upgrader
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        nft = dreWithdrawalNFT(address(proxy));

        vm.prank(defaultAdmin);
        nft.setDreUSDManager(manager);
    }

    function test_setDreUSDManager_EmitsEvent() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, false);
        emit IWithdrawalNFT.DreUSDManagerUpdated(manager, newManager);

        vm.prank(defaultAdmin);
        nft.setDreUSDManager(newManager);

        assertEq(nft.dreUSDManager(), newManager);
    }

    // ============ Initialization Tests ============

    function test_Initialize_Success() public  {
        assertEq(nft.name(), "DRE Withdrawal");
        assertEq(nft.symbol(), "dreWD");
        assertEq(nft.nextTokenId(), 1);
        assertTrue(nft.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(nft.hasRole(UPGRADER_ROLE, upgrader));
    }

    function test_Initialize_RevertIf_ZeroDefaultAdmin() public {
        dreUSD = new DreUSDMock();
        dreWithdrawalNFT newImplementation = new dreWithdrawalNFT();
        bytes memory initData = abi.encodeWithSelector(
            dreWithdrawalNFT.initialize.selector,
            address(dreUSD),
            "DRE Withdrawal",
            "dreWD",
            address(0),
            upgrader
        );

        vm.expectRevert(IWithdrawalNFT.ZeroAddress.selector);
        new ERC1967Proxy(address(newImplementation), initData);
    }

    function test_Initialize_RevertIf_ZeroDreUSD() public {
        dreWithdrawalNFT newImplementation = new dreWithdrawalNFT();
        bytes memory initData = abi.encodeWithSelector(
            dreWithdrawalNFT.initialize.selector,
            address(0),
            "DRE Withdrawal",
            "dreWD",
            defaultAdmin,
            upgrader
        );

        vm.expectRevert(IWithdrawalNFT.ZeroAddress.selector);
        new ERC1967Proxy(address(newImplementation), initData);
    }

    function test_Initialize_RevertIf_AlreadyInitialized() public {
        dreUSD = new DreUSDMock();
        vm.expectRevert();
        nft.initialize(address(dreUSD), "DRE Withdrawal", "dreWD", defaultAdmin, upgrader);
    }

    // ============ setDreUSD Tests ============

    function test_SetDreUSD_Success() public {
        assertEq(nft.dreUSD(), address(dreUSD));
        address newDreUSD = makeAddr("newDreUSD");
        vm.expectEmit(true, true, false, true);
        emit DreUSDUpdated(newDreUSD);
        vm.prank(defaultAdmin);
        nft.setDreUSD(newDreUSD);
        assertEq(nft.dreUSD(), newDreUSD);
    }

    function test_SetDreUSD_RevertIf_NotDefaultAdmin() public {
        address newDreUSD = makeAddr("newDreUSD");
        vm.prank(unauthorized);
        vm.expectRevert();
        nft.setDreUSD(newDreUSD);
        assertEq(nft.dreUSD(), address(dreUSD));
    }

    function test_SetDreUSD_RevertIf_ZeroAddress() public {
        vm.prank(defaultAdmin);
        vm.expectRevert(IWithdrawalNFT.ZeroAddress.selector);
        nft.setDreUSD(address(0));
        assertEq(nft.dreUSD(), address(dreUSD));
    }

    function test_SetDreUSD_RevertIf_SameValue() public {
        vm.prank(defaultAdmin);
        vm.expectRevert(IWithdrawalNFT.SameDreUSD.selector);
        nft.setDreUSD(address(dreUSD));
    }

    // ============ Mint Tests ============

    function test_Mint_Success() public {
        vm.expectEmit(true, true, false, true);
        emit PositionCreated(1, user1, USDC_AMOUNT_1, block.timestamp);

        vm.prank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);

        assertEq(tokenId, 1);
        assertEq(nft.nextTokenId(), 2);
        assertEq(nft.ownerOf(tokenId), user1);
        assertEq(nft.balanceOf(user1), 1);

        IWithdrawalNFT.Position memory position = nft.getPosition(tokenId);
        assertEq(position.user, user1);
        assertEq(position.usdcAmount, USDC_AMOUNT_1);
        assertEq(position.createdAt, block.timestamp);
    }

    function test_Mint_MultipleTokens() public {
        vm.startPrank(manager);

        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 tokenId2 = nft.mint(user2, USDC_AMOUNT_2);
        uint256 tokenId3 = nft.mint(user1, USDC_AMOUNT_1);

        vm.stopPrank();

        assertEq(tokenId1, 1);
        assertEq(tokenId2, 2);
        assertEq(tokenId3, 3);
        assertEq(nft.nextTokenId(), 4);
        assertEq(nft.balanceOf(user1), 2);
        assertEq(nft.balanceOf(user2), 1);
    }

    function test_Mint_RevertIf_ZeroAddress() public {
        vm.prank(manager);
        vm.expectRevert(IWithdrawalNFT.ZeroAddress.selector);
        nft.mint(address(0), USDC_AMOUNT_1);
    }

    function test_Mint_RevertIf_ZeroAmount() public {
        vm.prank(manager);
        vm.expectRevert(IWithdrawalNFT.ZeroAmount.selector);
        nft.mint(user1, 0);
    }

    function test_Mint_RevertIf_NotDreUSDManager() public {
        vm.prank(unauthorized);
        vm.expectRevert(IWithdrawalNFT.InvalidCaller.selector);
        nft.mint(user1, USDC_AMOUNT_1);
    }

    function test_Mint_WithCustomMinter() public {
        vm.prank(defaultAdmin);
        nft.setDreUSDManager(minter);

        vm.prank(minter);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(tokenId), user1);
    }

    // ============ Burn Tests ============

    function test_Burn_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        IWithdrawalNFT.Position memory position = nft.getPosition(tokenId);
        address owner = nft.ownerOf(tokenId);

        vm.expectEmit(true, true, true, true);
        emit PositionFilled(tokenId, owner, position.usdcAmount, manager);

        vm.prank(manager);
        nft.burn(tokenId);

        assertEq(nft.balanceOf(user1), 0);
        vm.expectRevert();
        nft.ownerOf(tokenId);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalNFT.PositionNotFound.selector, tokenId));
        nft.getPosition(tokenId);
    }

    function test_Burn_MultipleTokens() public {
        vm.startPrank(manager);
        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 tokenId2 = nft.mint(user2, USDC_AMOUNT_2);
        uint256 tokenId3 = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        assertEq(nft.balanceOf(user1), 2);
        assertEq(nft.balanceOf(user2), 1);

        vm.startPrank(manager);
        nft.burn(tokenId1);
        nft.burn(tokenId3);
        vm.stopPrank();

        assertEq(nft.balanceOf(user1), 0);
        assertEq(nft.balanceOf(user2), 1);
        assertTrue(nft.positionExists(tokenId2));
        assertFalse(nft.positionExists(tokenId1));
        assertFalse(nft.positionExists(tokenId3));
    }

    function test_Burn_RevertIf_PositionNotFound() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalNFT.PositionNotFound.selector, 1));
        nft.burn(1);
    }

    function test_Burn_RevertIf_AlreadyBurned() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        nft.burn(tokenId);
        vm.stopPrank();

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalNFT.PositionNotFound.selector, tokenId));
        nft.burn(tokenId);
    }

    function test_Burn_RevertIf_NotDreUSDManager() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(IWithdrawalNFT.InvalidCaller.selector);
        nft.burn(tokenId);
    }

    function test_Burn_WithCustomBurner() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.prank(defaultAdmin);
        nft.setDreUSDManager(burner);

        vm.prank(burner);
        nft.burn(tokenId);

        assertEq(nft.balanceOf(user1), 0);
    }

    // ============ View Function Tests ============

    function test_GetPosition_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        IWithdrawalNFT.Position memory position = nft.getPosition(tokenId);

        assertEq(position.user, user1);
        assertEq(position.usdcAmount, USDC_AMOUNT_1);
        assertEq(position.createdAt, block.timestamp);
    }

    function test_GetPosition_RevertIf_PositionNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalNFT.PositionNotFound.selector, 1));
        nft.getPosition(1);
    }

    function test_GetPositions_Success() public {
        vm.startPrank(manager);
        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 tokenId2 = nft.mint(user2, USDC_AMOUNT_2);
        uint256 tokenId3 = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;
        tokenIds[2] = tokenId3;

        IWithdrawalNFT.Position[] memory positions = nft.getPositions(tokenIds);

        assertEq(positions.length, 3);
        assertEq(positions[0].user, user1);
        assertEq(positions[0].usdcAmount, USDC_AMOUNT_1);
        assertEq(positions[0].createdAt, block.timestamp);
        assertEq(positions[1].user, user2);
        assertEq(positions[1].usdcAmount, USDC_AMOUNT_2);
        assertEq(positions[1].createdAt, block.timestamp);
        assertEq(positions[2].user, user1);
        assertEq(positions[2].usdcAmount, USDC_AMOUNT_1);
        assertEq(positions[2].createdAt, block.timestamp);
    }

    function test_GetPositions_EmptyArray() public  {
        uint256[] memory tokenIds = new uint256[](0);
        IWithdrawalNFT.Position[] memory positions = nft.getPositions(tokenIds);
        assertEq(positions.length, 0);
    }

    function test_GetPositions_SingleId() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        IWithdrawalNFT.Position[] memory positions = nft.getPositions(tokenIds);

        assertEq(positions.length, 1);
        assertEq(positions[0].user, user1);
        assertEq(positions[0].usdcAmount, USDC_AMOUNT_1);
    }

    function test_GetPositions_RevertIf_PositionNotFound() public {
        vm.startPrank(manager);
        nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 99; // does not exist

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalNFT.PositionNotFound.selector, 99));
        nft.getPositions(tokenIds);
    }

    function test_GetTokensByIndexes_Success() public {
        vm.startPrank(manager);
        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 tokenId2 = nft.mint(user2, USDC_AMOUNT_2);
        uint256 tokenId3 = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        uint256[] memory indexes = new uint256[](3);
        indexes[0] = 0;
        indexes[1] = 1;
        indexes[2] = 2;

        uint256[] memory tokenIds = nft.getTokensByIndexes(indexes);

        assertEq(tokenIds.length, 3);
        assertEq(tokenIds[0], tokenId1);
        assertEq(tokenIds[1], tokenId2);
        assertEq(tokenIds[2], tokenId3);
    }

    function test_GetTokensByIndexes_EmptyArray() public  {
        uint256[] memory indexes = new uint256[](0);
        uint256[] memory tokenIds = nft.getTokensByIndexes(indexes);
        assertEq(tokenIds.length, 0);
    }

    function test_GetTokensByIndexes_NonSequentialIndexes() public {
        vm.startPrank(manager);
        nft.mint(user1, USDC_AMOUNT_1);
        nft.mint(user2, USDC_AMOUNT_2);
        nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 2;
        indexes[1] = 0;

        uint256[] memory tokenIds = nft.getTokensByIndexes(indexes);

        assertEq(tokenIds.length, 2);
        assertEq(tokenIds[0], 3);
        assertEq(tokenIds[1], 1);
    }

    function test_GetTokensByIndexes_RevertIf_IndexOutOfBounds() public {
        vm.startPrank(manager);
        nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 1; // only index 0 is valid (totalSupply == 1)

        vm.expectRevert();
        nft.getTokensByIndexes(indexes);
    }

    function test_GetUsdcAmount_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        uint256 usdcAmount = nft.getUsdcAmount(tokenId);
        assertEq(usdcAmount, USDC_AMOUNT_1);
    }

    function test_GetUsdcAmount_RevertIf_PositionNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalNFT.PositionNotFound.selector, 1));
        nft.getUsdcAmount(1);
    }

    function test_PositionExists_True() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        assertTrue(nft.positionExists(tokenId));
    }

    function test_PositionExists_False() public  {
        assertFalse(nft.positionExists(1));
    }

    function test_PositionExists_FalseAfterBurn() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        nft.burn(tokenId);
        vm.stopPrank();

        assertFalse(nft.positionExists(tokenId));
    }

    function test_GetOriginalUser_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        address originalUser = nft.getOriginalUser(tokenId);
        assertEq(originalUser, user1);
    }

    function test_GetOriginalUser_RevertIf_PositionNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalNFT.PositionNotFound.selector, 1));
        nft.getOriginalUser(1);
    }

    function test_GetOriginalUser_AfterTransfer() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Transfer NFT to another user
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        // Original user should still be user1
        address originalUser = nft.getOriginalUser(tokenId);
        assertEq(originalUser, user1);
        assertEq(nft.ownerOf(tokenId), user2);
    }

    // ============ Pending Range Tests ============

    function test_GetPendingRange_NoMints() public  {
        (uint256 startId, uint256 endId) = nft.getPendingRange();
        assertEq(startId, 1);
        assertEq(endId, 0);
    }

    function test_GetPendingRange_SequentialMintsAndBurns() public {
        vm.startPrank(manager);
        uint256 id1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 id2 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 id3 = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        (uint256 startId, uint256 endId) = nft.getPendingRange();
        assertEq(startId, id1);
        assertEq(endId, id3);

        // Burn in order: 1, then 2, then 3
        vm.prank(manager);
        nft.burn(id1);
        (startId, endId) = nft.getPendingRange();
        assertEq(startId, id2);
        assertEq(endId, id3);

        vm.prank(manager);
        nft.burn(id2);
        vm.prank(manager);
        nft.burn(id3);

        (startId, endId) = nft.getPendingRange();
        assertEq(startId, id3 + 1);
        assertEq(endId, id3); // empty main range
    }

    function test_GetPendingRange_OutOfOrderBurns() public {
        vm.startPrank(manager);
        uint256 id1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 id2 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 id3 = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Burn highest ID first -> lastBurnedTokenId advances, pending range becomes empty
        vm.prank(manager);
        nft.burn(id3);

        (uint256 startId, uint256 endId) = nft.getPendingRange();
        assertEq(startId, id3 + 1);
        assertEq(endId, id3); // empty main range (start > end)

        // id1 and id2 still exist and can be burned
        assertTrue(nft.positionExists(id1));
        assertTrue(nft.positionExists(id2));

        vm.prank(manager);
        nft.burn(id1);
        vm.prank(manager);
        nft.burn(id2);

        assertFalse(nft.positionExists(id1));
        assertFalse(nft.positionExists(id2));
    }

    // ============ ERC721 Functionality Tests ============

    function test_Transfer_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        assertEq(nft.ownerOf(tokenId), user2);
        assertEq(nft.balanceOf(user1), 0);
        assertEq(nft.balanceOf(user2), 1);

        // Position data should remain unchanged
        IWithdrawalNFT.Position memory position = nft.getPosition(tokenId);
        assertEq(position.user, user1); // Original user preserved
    }

    function test_SafeTransferFrom_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.prank(user1);
        nft.safeTransferFrom(user1, user2, tokenId);

        assertEq(nft.ownerOf(tokenId), user2);
    }

    function test_SafeTransferFrom_WithData_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.prank(user1);
        nft.safeTransferFrom(user1, user2, tokenId, "");

        assertEq(nft.ownerOf(tokenId), user2);
    }

    function test_Approve_Success() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.prank(user1);
        nft.approve(user2, tokenId);

        assertEq(nft.getApproved(tokenId), user2);
    }

    function test_SetApprovalForAll_Success() public {
        vm.startPrank(manager);
        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 tokenId2 = nft.mint(user1, USDC_AMOUNT_2);
        vm.stopPrank();

        vm.prank(user1);
        nft.setApprovalForAll(user2, true);

        assertTrue(nft.isApprovedForAll(user1, user2));

        // user2 should be able to transfer both tokens
        vm.prank(user2);
        nft.transferFrom(user1, user2, tokenId1);

        vm.prank(user2);
        nft.transferFrom(user1, user2, tokenId2);

        assertEq(nft.balanceOf(user2), 2);
    }

    // ============ ERC721Enumerable Tests ============

    function test_TotalSupply() public {
        assertEq(nft.totalSupply(), 0);

        vm.startPrank(manager);
        nft.mint(user1, USDC_AMOUNT_1);
        assertEq(nft.totalSupply(), 1);

        nft.mint(user2, USDC_AMOUNT_2);
        assertEq(nft.totalSupply(), 2);

        nft.burn(1);
        assertEq(nft.totalSupply(), 1);
        vm.stopPrank();
    }

    function test_TokenByIndex() public {
        vm.startPrank(manager);
        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        nft.mint(user2, USDC_AMOUNT_2);
        uint256 tokenId3 = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        assertEq(nft.tokenByIndex(0), tokenId1);
        assertEq(nft.tokenByIndex(1), 2);
        assertEq(nft.tokenByIndex(2), tokenId3);
    }

    function test_TokenOfOwnerByIndex() public {
        vm.startPrank(manager);
        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        uint256 tokenId2 = nft.mint(user2, USDC_AMOUNT_2);
        uint256 tokenId3 = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        assertEq(nft.tokenOfOwnerByIndex(user1, 0), tokenId1);
        assertEq(nft.tokenOfOwnerByIndex(user1, 1), tokenId3);
        assertEq(nft.tokenOfOwnerByIndex(user2, 0), tokenId2);
    }

    // ============ Access Control Tests ============

    function test_Roles_InitialSetup() public  {
        assertTrue(nft.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(nft.hasRole(UPGRADER_ROLE, upgrader));
        assertEq(nft.dreUSDManager(), manager);
    }

    function test_SetDreUSDManager() public {
        vm.prank(defaultAdmin);
        nft.setDreUSDManager(minter);
        assertEq(nft.dreUSDManager(), minter);

        vm.prank(defaultAdmin);
        nft.setDreUSDManager(burner);
        assertEq(nft.dreUSDManager(), burner);
    }

    function test_RevokeDreUSDManagerRevertsMint() public {
        vm.prank(defaultAdmin);
        nft.setDreUSDManager(unauthorized); // manager no longer allowed

        vm.prank(manager);
        vm.expectRevert(IWithdrawalNFT.InvalidCaller.selector);
        nft.mint(user1, USDC_AMOUNT_1);
    }

    function test_SetDreUSDManager_RevertIf_NotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        nft.setDreUSDManager(minter);
    }

    // ============ Upgrade Tests ============

    function test_Upgrade_Success() public {
        dreWithdrawalNFT newImplementation = new dreWithdrawalNFT();

        vm.startPrank(upgrader);
        nft.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // Verify the proxy still works
        assertEq(nft.name(), "DRE Withdrawal");
    }

    function test_Upgrade_RevertIf_NotUpgrader() public {
        dreWithdrawalNFT newImplementation = new dreWithdrawalNFT();

        vm.prank(unauthorized);
        vm.expectRevert();
        nft.upgradeToAndCall(address(newImplementation), "");
    }

    // ============ Edge Cases ============

    function test_TokenId_IncrementsCorrectly() public {
        vm.startPrank(manager);

        uint256 tokenId1 = nft.mint(user1, USDC_AMOUNT_1);
        assertEq(nft.nextTokenId(), 2);

        uint256 tokenId2 = nft.mint(user2, USDC_AMOUNT_2);
        assertEq(tokenId2, 2);
        assertEq(nft.nextTokenId(), 3);

        // Burn tokenId1, but nextTokenId should still increment
        nft.burn(tokenId1);
        assertEq(nft.nextTokenId(), 3); // Should not change

        uint256 tokenId3 = nft.mint(user1, USDC_AMOUNT_1);
        assertEq(tokenId3, 3);
        assertEq(nft.nextTokenId(), 4);

        vm.stopPrank();
    }

    function test_MultipleUsers_MultiplePositions() public {
        vm.startPrank(manager);

        // User1 gets 3 positions
        nft.mint(user1, USDC_AMOUNT_1);
        nft.mint(user1, USDC_AMOUNT_2);
        nft.mint(user1, USDC_AMOUNT_1);

        // User2 gets 2 positions
        nft.mint(user2, USDC_AMOUNT_2);
        nft.mint(user2, USDC_AMOUNT_1);

        vm.stopPrank();

        assertEq(nft.balanceOf(user1), 3);
        assertEq(nft.balanceOf(user2), 2);
        assertEq(nft.totalSupply(), 5);

        // Verify all positions
        assertEq(nft.getUsdcAmount(1), USDC_AMOUNT_1);
        assertEq(nft.getUsdcAmount(2), USDC_AMOUNT_2);
        assertEq(nft.getUsdcAmount(3), USDC_AMOUNT_1);
        assertEq(nft.getUsdcAmount(4), USDC_AMOUNT_2);
        assertEq(nft.getUsdcAmount(5), USDC_AMOUNT_1);
    }

    function test_SupportsInterface() public {
        // ERC721
        assertTrue(nft.supportsInterface(0x80ac58cd));
        // ERC721Enumerable
        assertTrue(nft.supportsInterface(0x780e9d63));
        // AccessControl
        assertTrue(nft.supportsInterface(0x7965db0b));
        // IWithdrawalNFT (ERC165)
        assertTrue(nft.supportsInterface(0x01ffc9a7));
    }

    // ============ Integration Tests ============

    function test_FullLifecycle() public {
        // 1. Mint position
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        assertTrue(nft.positionExists(tokenId));
        assertEq(nft.ownerOf(tokenId), user1);
        assertEq(nft.getUsdcAmount(tokenId), USDC_AMOUNT_1);

        // 2. Transfer NFT
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        assertEq(nft.ownerOf(tokenId), user2);
        assertEq(nft.getOriginalUser(tokenId), user1); // Original user preserved

        // 3. Burn position (filled)
        vm.prank(manager);
        nft.burn(tokenId);

        assertFalse(nft.positionExists(tokenId));
        vm.expectRevert();
        nft.ownerOf(tokenId);
    }

    // ============ Sanctions Validation Tests (_update) ============

    function test_Update_RevertIf_TransferToSanctionedAddress() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Sanction the recipient
        sanctionsList.setSanctioned(user2, true);

        // Attempt to transfer to sanctioned address
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        nft.transferFrom(user1, user2, tokenId);
    }

    function test_Update_RevertIf_TransferFromSanctionedAddress() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Transfer to user2 first
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        // Sanction user2 (current owner)
        sanctionsList.setSanctioned(user2, true);

        // Attempt to transfer from sanctioned address
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        nft.transferFrom(user2, user1, tokenId);
    }

    function test_Update_RevertIf_ApprovedAddressIsSanctioned() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Sanction the approved address
        sanctionsList.setSanctioned(user2, true);

        // Approve sanctioned address
        vm.prank(user1);
        nft.approve(user2, tokenId);

        // Attempt to transfer using sanctioned approved address
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        nft.transferFrom(user1, user2, tokenId);
    }

    function test_Update_RevertIf_MintToSanctionedAddress() public {
        // Sanction user1
        sanctionsList.setSanctioned(user1, true);

        // Attempt to mint to sanctioned address
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        nft.mint(user1, USDC_AMOUNT_1);
    }

    function test_Update_Success_NormalTransfer() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Normal transfer should work
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        assertEq(nft.ownerOf(tokenId), user2);
    }

    function test_Update_RevertIf_BurnWhenOwnerSanctioned() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Sanction user1 (the owner)
        sanctionsList.setSanctioned(user1, true);

        // Burn should fail because owner is sanctioned (owner is validated even when to == address(0))
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        nft.burn(tokenId);
    }

    function test_Update_Success_Burn() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Burn should work when owner is not sanctioned
        vm.prank(manager);
        nft.burn(tokenId);

        assertFalse(nft.positionExists(tokenId));
    }

    function test_Update_Success_TransferAfterSanctionRemoved() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Sanction user2
        sanctionsList.setSanctioned(user2, true);

        // Transfer should fail
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        nft.transferFrom(user1, user2, tokenId);

        // Remove sanction
        sanctionsList.setSanctioned(user2, false);

        // Transfer should now succeed
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        assertEq(nft.ownerOf(tokenId), user2);
    }

    function test_Update_RevertIf_FrozenAddress() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Freeze user2
        dreUSD.freeze(user2);

        // Attempt to transfer to frozen address
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        nft.transferFrom(user1, user2, tokenId);
    }

    function test_Update_RevertIf_TransferFromFrozenAddress() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Transfer to user2 first
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        // Freeze user2
        dreUSD.freeze(user2);

        // Attempt to transfer from frozen address
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        nft.transferFrom(user2, user1, tokenId);
    }

    function test_Update_Success_SetApprovalForAllSanctionedOperator() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Sanction operator
        sanctionsList.setSanctioned(user2, true);

        // setApprovalForAll should succeed (no validation on approve)
        vm.prank(user1);
        nft.setApprovalForAll(user2, true);

        // But transfer should fail
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        nft.transferFrom(user1, user2, tokenId);
    }

    function test_Update_Success_ApproveSanctionedOperator() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Sanction operator
        sanctionsList.setSanctioned(user2, true);

        // Approve should succeed (no validation on approve)
        vm.prank(user1);
        nft.approve(user2, tokenId);

        // But transfer should fail
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        nft.transferFrom(user1, user2, tokenId);
    }

    function test_Update_Success_SafeTransferFrom() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Normal safeTransferFrom should work
        vm.prank(user1);
        nft.safeTransferFrom(user1, user2, tokenId);

        assertEq(nft.ownerOf(tokenId), user2);
    }

    function test_Update_RevertIf_SafeTransferFromToSanctioned() public {
        vm.startPrank(manager);
        uint256 tokenId = nft.mint(user1, USDC_AMOUNT_1);
        vm.stopPrank();

        // Sanction recipient
        sanctionsList.setSanctioned(user2, true);

        // safeTransferFrom should fail
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        nft.safeTransferFrom(user1, user2, tokenId);
    }
}
