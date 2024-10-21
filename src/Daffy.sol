// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "@thirdweb-dev/contracts/base/ERC721Base.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Daffy is VRFConsumerBaseV2Plus {
    // Defining custom errors
    error Daffy__transferFailed();
    error Daffy__DaffyNotOpen();
    error Daffy__NotAuthorized();
    error Daffy__InvalidStatus();
    error Daffy_IncorrectPayment();
    error Daffy_DaffyDoesNotOwnNFT();
    error Daffy_NoNFTPrizesAdded();
    error Daffy_CannotDeleteActiveDaffy();
    error Daffy_WrongRequestId();
    error Daffy_InvalidPick();
    error Daffy_InvalidPercentage();

    // Chainlink VRF variables
    uint256 public s_subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 2;

    // State variables
    enum DaffyState {
        INACTIVE,
        ACTIVE,
        CALCULATING,
        ENDED,
        DELETED
    }

    address public immutable factoryAddress;
    address public immutable daffyCreator;
    string public name;
    string public description;
    string public tags;
    mapping(address => uint256) public entryCounts;
    address payable[] public players;
    uint256 public ticketCost;
    uint256 public totalEntries;
    uint256 public creationTime;
    uint256 public daffyCreatorPercentage;
    uint256 public constant PLATFORM_FEE_PERCENTAGE = 3;
    uint256 private constant PERCENTAGE_BASE = 100;
    address private s_recentWinner;
    DaffyState public s_daffyState;
    uint256 public s_requestId;
    uint256[] public s_randomWords;

    struct NFTPrize {
        address nftContract;
        uint256 tokenId;
    }

    NFTPrize[] public nftPrizes;

    // events
    event NewTicketBought(address indexed player);
    event DaffyActivated();
    event DaffyDeleted();
    event Winner(address indexed winner, uint256 ethPrize);
    event NFTAwarded(
        address indexed winner,
        address nftContract,
        uint256 tokenId
    );
    event TicketCostChanged(uint256 newCost);
    event NFTPrizeAdded(address indexed nftContract, uint256 tokenId);
    event RandomWordsRequested(uint256 requestId);
    event PrizeSplitUpdated(uint256 daffyCreatorPercentage);
    event DaffyCancelled();
    event DescriptionUpdated(string newDescription);
    event TagsUpdated(string newTags);

    // modifiers
    modifier onlyFactory() {
        if (msg.sender != factoryAddress) revert Daffy__NotAuthorized();
        _;
    }

    modifier onlyDaffyCreator() {
        if (msg.sender != daffyCreator) revert Daffy__NotAuthorized();
        _;
    }

    modifier inState(DaffyState state) {
        if (s_daffyState != state) revert Daffy__InvalidStatus();
        _;
    }

    constructor(
        string memory _name,
        uint256 _ticketCost,
        address _daffyCreator,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint256 _daffyCreatorPercentage,
        string memory _description,
        string memory _tags,
        address _factory
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        daffyCreator = _daffyCreator;
        name = _name;
        ticketCost = _ticketCost;
        s_subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        daffyCreatorPercentage = _daffyCreatorPercentage;
        description = _description;
        tags = _tags;
        factoryAddress = _factory;
        s_daffyState = DaffyState.INACTIVE;
        creationTime = block.timestamp;

        emit PrizeSplitUpdated(_daffyCreatorPercentage);
        emit DescriptionUpdated(_description);
        emit TagsUpdated(_tags);
    }

    // Allow users buy ticket to a daffy if the daffy status is active
    function buyTicket(
        uint256 numberOfTickets
    ) external payable inState(DaffyState.ACTIVE) {
        // One thing to note is the sent Ether (msg.value) is automatically added to the contract's balance
        if (msg.value != ticketCost * numberOfTickets)
            revert Daffy_IncorrectPayment();

        entryCounts[msg.sender] += numberOfTickets;
        totalEntries += numberOfTickets;

        if (entryCounts[msg.sender] == numberOfTickets) {
            players.push(payable(msg.sender));
        }

        emit NewTicketBought(msg.sender);
    }

    // Add nfts to nftPrizes array
    function addNFTPrize(
        address _nftContract,
        uint256 _tokenId
    ) external onlyFactory inState(DaffyState.INACTIVE) {
        if (ERC721Base(_nftContract).ownerOf(_tokenId) != address(this))
            revert Daffy_DaffyDoesNotOwnNFT();

        nftPrizes.push(NFTPrize(_nftContract, _tokenId));
        emit NFTPrizeAdded(_nftContract, _tokenId);
    }

    // Helper function to set daffy state to active
    function setActive() external onlyFactory inState(DaffyState.INACTIVE) {
        if (nftPrizes.length == 0) revert Daffy_NoNFTPrizesAdded();
        s_daffyState = DaffyState.ACTIVE;
        emit DaffyActivated();
    }

    // Helper function to set daffy state to deleted
    function setDeleted() external onlyFactory {
        if (
            s_daffyState != DaffyState.INACTIVE ||
            s_daffyState != DaffyState.ENDED
        ) revert Daffy_CannotDeleteActiveDaffy();

        s_daffyState = DaffyState.DELETED;
        emit DaffyDeleted();
    }

    // using chainlink vrf request a random word
    function requestRandomWords() internal {
        s_daffyState = DaffyState.CALCULATING;
        s_requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );
        emit RandomWordsRequested(s_requestId);
    }

    // Get random words and call the pickWinner function
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        if (requestId != s_requestId) revert Daffy_WrongRequestId();
        s_randomWords = randomWords;
        pickWinner();
    }

    // pick a winner and set daffy state to ended
    function pickWinner() private {
        if (players.length == 0 && nftPrizes.length == 0)
            revert Daffy_InvalidPick();

        uint256 winnerIndex = s_randomWords[0] % players.length;
        address payable winner = players[winnerIndex];

        uint256 totalPrizePool = address(this).balance;
        uint256 platformFee = (totalPrizePool * PLATFORM_FEE_PERCENTAGE) /
            PERCENTAGE_BASE;
        uint256 daffyCreatorPrize = (totalPrizePool * daffyCreatorPercentage) /
            PERCENTAGE_BASE;
        uint256 winnerPrize = totalPrizePool - platformFee - daffyCreatorPrize;

        bool success;

        (success, ) = payable(factoryAddress).call{value: platformFee}("");
        if (!success) revert Daffy__transferFailed();

        (success, ) = payable(daffyCreator).call{value: daffyCreatorPrize}("");
        if (!success) revert Daffy__transferFailed();

        (success, ) = winner.call{value: winnerPrize}("");
        if (!success) revert Daffy__transferFailed();

        s_recentWinner = winner;
        emit Winner(winner, winnerPrize);

        // Transfer all NFT prizes to the winner
        for (uint256 i = 0; i < nftPrizes.length; i++) {
            ERC721Base(nftPrizes[i].nftContract).transferFrom(
                address(this),
                winner,
                nftPrizes[i].tokenId
            );
            emit NFTAwarded(
                winner,
                nftPrizes[i].nftContract,
                nftPrizes[i].tokenId
            );
        }

        s_daffyState = DaffyState.ENDED;
    }

    function changeTicketCost(
        uint256 _newCost
    ) external onlyDaffyCreator inState(DaffyState.INACTIVE) {
        ticketCost = _newCost;
        emit TicketCostChanged(_newCost);
    }

    function updatePrizeSplit(
        uint256 _daffyCreatorPercentage
    ) external onlyDaffyCreator inState(DaffyState.INACTIVE) {
        if (_daffyCreatorPercentage >= 80) revert Daffy_InvalidPercentage();
        daffyCreatorPercentage = _daffyCreatorPercentage;
        emit PrizeSplitUpdated(_daffyCreatorPercentage);
    }

    function cancelDaffy()
        external
        onlyDaffyCreator
        inState(DaffyState.INACTIVE)
    {
        for (uint256 i = 0; i < nftPrizes.length; i++) {
            ERC721Base(nftPrizes[i].nftContract).transferFrom(
                address(this),
                daffyCreator,
                nftPrizes[i].tokenId
            );
        }
        delete nftPrizes;
        s_daffyState = DaffyState.DELETED;
        emit DaffyCancelled();
    }

    function getPlayers() external view returns (address payable[] memory) {
        return players;
    }

    function getNFTPrizes() external view returns (NFTPrize[] memory) {
        return nftPrizes;
    }

    function updateDescription(
        string memory _newDescription
    ) external onlyDaffyCreator {
        description = _newDescription;
        emit DescriptionUpdated(_newDescription);
    }

    function updateTags(string memory _newTags) external onlyDaffyCreator {
        tags = _newTags;
        emit TagsUpdated(_newTags);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// event DaffyEndingInitiated(uint256 timestamp);

// function initiateEndDaffy() external onlyFactory inState(DaffyState.ACTIVE) {
//     require(players.length >= MIN_PLAYERS, "Not enough players");
//     require(block.timestamp >= creationTime + MIN_DURATION, "Daffy duration not met");

//     emit DaffyEndingInitiated(block.timestamp);
//     requestRandomWords();
// }
