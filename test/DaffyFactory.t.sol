// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/DaffyFactory.sol";
import "../src/Daffy.sol";

// Simplified mock ERC721 interface with a unique name
interface IMockERC721 {
    function balanceOf(address owner) external view returns (uint256 balance);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function transferFrom(address from, address to, uint256 tokenId) external;

    function approve(address to, uint256 tokenId) external;
}

contract DaffyFactoryTest is Test {
    DaffyFactory public factory;
    address public ayobami;
    address public joe;

    // Mock VRF Coordinator parameters
    address constant MOCK_VRF_COORDINATOR = address(0x1);
    uint256 constant MOCK_SUBSCRIPTION_ID = 1;
    bytes32 constant MOCK_KEY_HASH = bytes32(uint256(1));

    function setUp() public {
        factory = new DaffyFactory(
            MOCK_VRF_COORDINATOR,
            MOCK_SUBSCRIPTION_ID,
            MOCK_KEY_HASH
        );
        ayobami = makeAddr("ayobami");
        joe = makeAddr("joe");
        vm.deal(ayobami, 100 ether);
        vm.deal(joe, 100 ether);
    }

    function testCreateDaffy() public {
        vm.startPrank(ayobami);

        address[] memory nftContracts = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        nftContracts[0] = address(new MockNFT());
        tokenIds[0] = 1;

        // Mint an NFT to Ayobami
        MockNFT(nftContracts[0]).mint(ayobami, 1);

        // Approve the factory to transfer the NFT
        MockNFT(nftContracts[0]).approve(address(factory), 1);

        factory.createDaffy(
            0.1 ether,
            "Test Daffy",
            10,
            "Test Description",
            "Test Tags"
            // nftContracts,
            // tokenIds
        );

        DaffyFactory.DaffyInfo[] memory ayobamiDaffys = factory.getUserDaffys(
            ayobami
        );
        assertEq(
            ayobamiDaffys.length,
            1,
            "Ayobami should have created one Daffy"
        );
        assertEq(
            ayobamiDaffys[0].name,
            "Test Daffy",
            "Daffy name should match"
        );
        assertEq(
            ayobamiDaffys[0].ticketCost,
            0.1 ether,
            "Ticket cost should match"
        );

        vm.stopPrank();
    }
}

// Simplified mock NFT contract for testing
contract MockNFT is IMockERC721 {
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;

    function mint(address to, uint256 tokenId) public {
        _owners[tokenId] = to;
        _balances[to]++;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "Not the owner");
        _owners[tokenId] = to;
        _balances[from]--;
        _balances[to]++;
    }

    function approve(address to, uint256 tokenId) external {
        _tokenApprovals[tokenId] = to;
    }
}
