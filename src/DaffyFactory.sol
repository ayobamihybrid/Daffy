// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Daffy.sol";

// Defining custom errors
error DaffyFactory__creatorPercentageTooHigh();
error DaffyFactory__InvalidTicketCost(uint256 cost);
error DaffyFactory__DaffyCreationFailed();
error DaffyFactory__InvalidDaffyAddress();
error DaffyFactory__creatorDoesNotOwnNFT(uint256 index);
error DaffyFactory__mismatchedNFTArrays();
error DaffyFactory__atleastOneNFTRequired();
error DaffyFactory__DaffyAlreadyActive();
error DaffyFactory__DaffyNotFound();
error DaffyFactory__NotAuthorized();

contract DaffyFactory {
    // Using a string library because we need to cast number to string which is directly not possible in solidity. No need to import the library above, a contract we're importing uses the custom Strings library or declared it within their own scope
    using Strings for uint256;

    enum DaffyStatus {
        Inactive,
        Active,
        Deleted
    }

    // How we want our daffy information to look like
    struct DaffyInfo {
        address daffyAddress;
        string name;
        uint256 ticketCost;
        uint256 creatorPercentage;
        string description;
        string tags;
        address creator;
        uint256 creationTime;
        DaffyStatus status;
    }

    // Chainlink VRF parameters
    address public immutable vrfCoordinator;
    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;

    // State variables

    // when a user successfully creates a daffy, the daffy they created would be stored in their address.
    mapping(address => DaffyInfo[]) public userDaffys;

    // returns all running daffys
    DaffyInfo[] public allDaffys;

    uint256 public constant MAX_TICKET_COST = 1 ether;
    uint256 public constant MAX_CREATOR_PERCENTAGE = 80;
    uint256 public constant ACTIVATION_WINDOW = 10 minutes;

    // Emit an event when a daffy is created
    event DaffyCreated(
        address indexed creator,
        address daffyAddress,
        string name,
        uint256 ticketCost,
        uint256 creatorPercentage,
        string description,
        string tags,
        uint256 creationTime
    );

    // emit an event when NFT prize is added to a daffy
    event NFTPrizeAdded(
        address indexed daffyAddress,
        address indexed nftContract,
        uint256 tokenId
    );

    // Emit event if daffy creation is successful
    event DaffyActivated(address indexed daffyAddress);

    // If daffy creation is not successful, emit daffy deleted event
    event DaffyDeleted(address indexed daffyAddress);

    // Emit an event when a daffy creation fails
    event DaffyCreationFailed(address indexed creator, string reason);

    // This constructor function will be called when this contract is deployed. We'd be prompted to input the 3 parameters below.
    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash
    ) {
        vrfCoordinator = _vrfCoordinator;
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
    }

    // Function to begin the process of creating a daffy!!!
    function createDaffy(
        uint256 _ticketCost,
        string memory _name,
        uint256 _creatorPercentage,
        string memory _description,
        string memory _tags
    ) public returns (address) {
        // The prizepool will be the total amount of tickets bought for a particular daffy, the creator of the daffy shouldn't take more than 80% of it, while we'd take 3% of it as platform fee, and the eventual winner of the daffy takes the rest including the added NFTs
        if (_creatorPercentage > MAX_CREATOR_PERCENTAGE)
            revert DaffyFactory__creatorPercentageTooHigh();

        // Setting a max ticket cost to regulate the maximum cost of a daffy ticket to avoid unreasonable ticket prices
        if (_ticketCost > MAX_TICKET_COST)
            revert DaffyFactory__InvalidTicketCost(_ticketCost);

        Daffy newDaffy = new Daffy(
            _name,
            _ticketCost,
            msg.sender,
            vrfCoordinator,
            subscriptionId,
            keyHash,
            _creatorPercentage,
            _description,
            _tags,
            address(this)
        );

        if (address(newDaffy) == address(0)) {
            revert DaffyFactory__DaffyCreationFailed();
        }

        // Register the time the daffy is created
        uint256 creationTime = block.timestamp;

        // Create and store the newly created daffy information for use, for example; in the frontend
        DaffyInfo memory newDaffyInfo = DaffyInfo(
            address(newDaffy),
            _name,
            _ticketCost,
            _creatorPercentage,
            _description,
            _tags,
            msg.sender,
            creationTime,
            DaffyStatus.Inactive
        );

        // inside the userDaffys variable declared above, push the newly created daffy information in to the address of the user that created it
        userDaffys[msg.sender].push(newDaffyInfo);

        // Also push into the allDaffys variable
        allDaffys.push(newDaffyInfo);

        emit DaffyCreated(
            msg.sender,
            address(newDaffy),
            _name,
            _ticketCost,
            _creatorPercentage,
            _description,
            _tags,
            creationTime
        );

        return address(newDaffy);
    }

    function addNFTPrizesToDaffy(
        address _daffyAddress,
        address[] memory _nftContracts,
        uint256[] memory _tokenIds
    ) public {
        // _daffyAddress should be the address assigned to the newly created daffy
        if (_daffyAddress == address(0)) {
            revert DaffyFactory__InvalidDaffyAddress();
        }
        // The provided NFTs should be the same length with the tokenIds; the NFTs added must each be unique
        if (_nftContracts.length != _tokenIds.length) {
            revert DaffyFactory__mismatchedNFTArrays();
        }
        // User trying to create a daffy must add atleast one NFT
        if (_nftContracts.length == 0) {
            revert DaffyFactory__atleastOneNFTRequired();
        }

        Daffy daffy = Daffy(_daffyAddress);

        // get the daffy information
        DaffyInfo storage daffyInfo = getDaffyInfo(_daffyAddress);

        // making sure the user is not adding the NFTs to an already active daffy
        if (daffyInfo.status == DaffyStatus.Active) {
            revert DaffyFactory__DaffyAlreadyActive();
        }

        // The user adding the NFTs should be the one that created the daffy in the first place
        if (msg.sender != daffyInfo.creator) {
            revert DaffyFactory__NotAuthorized();
        }

        for (uint256 i = 0; i < _nftContracts.length; i++) {
            IERC721 nftContract = IERC721(_nftContracts[i]);
            // The NFTs the user is trying to add must be theirs
            if (nftContract.ownerOf(_tokenIds[i]) != msg.sender) {
                revert DaffyFactory__creatorDoesNotOwnNFT(i);
            }

            // transfer the NFTs to the address of the newly created daffy
            nftContract.transferFrom(msg.sender, _daffyAddress, _tokenIds[i]);
            // add the NFTs to the nft prize array for that daffy
            daffy.addNFTPrize(_nftContracts[i], _tokenIds[i]);

            emit NFTPrizeAdded(_daffyAddress, _nftContracts[i], _tokenIds[i]);
        }

        daffyInfo.status = DaffyStatus.Active;
        daffy.setActive();
        emit DaffyActivated(_daffyAddress);
    }

    function deleteDaffy(address _daffyAddress) public {
        DaffyInfo storage daffyInfo = getDaffyInfo(_daffyAddress);

        if (msg.sender != daffyInfo.creator && msg.sender != address(this)) {
            revert DaffyFactory__NotAuthorized();
        }

        if (
            daffyInfo.status == DaffyStatus.Inactive &&
            block.timestamp > daffyInfo.creationTime + ACTIVATION_WINDOW
        ) {
            daffyInfo.status = DaffyStatus.Deleted;
            Daffy(_daffyAddress).setDeleted();
            emit DaffyDeleted(_daffyAddress);
        }
    }

    // To do: using chainlink... Implement a cron function or something(can't really remember the name right now) that calls this function every 10 minutes
    function checkAndDeleteInactiveDaffys() public {
        for (uint i = 0; i < allDaffys.length; i++) {
            if (
                allDaffys[i].status == DaffyStatus.Inactive &&
                block.timestamp > allDaffys[i].creationTime + ACTIVATION_WINDOW
            ) {
                deleteDaffy(allDaffys[i].daffyAddress);
            }
        }
    }

    // helper function to get daffy informations
    function getDaffyInfo(
        address _daffyAddress
    ) internal view returns (DaffyInfo storage) {
        for (uint i = 0; i < allDaffys.length; i++) {
            if (allDaffys[i].daffyAddress == _daffyAddress) {
                return allDaffys[i];
            }
        }
        revert DaffyFactory__DaffyNotFound();
    }

    // Get all the daffys created by a user
    function getUserDaffys(
        address user
    ) public view returns (DaffyInfo[] memory) {
        return userDaffys[user];
    }

    // Get all running daffys
    function getAllDaffys() public view returns (DaffyInfo[] memory) {
        return allDaffys;
    }
}
