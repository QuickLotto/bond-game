
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {VRFV2WrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";

contract BONDGAME is VRFV2WrapperConsumerBase, ConfirmedOwner {
    using SafeERC20 for IERC20;
    uint256 public lotteryRoundId;
    uint8 public platformShare;
    uint256 public bondPrice;
    uint32 public lotteryDuration;
    uint256 public minBalanceCheck;
    IERC20 public platformToken;
    uint32 public callbackGasLimit = 450000;
    uint16 public requestConfirmations = 3;
    uint32 numWords = 1;
    uint256 public minTimeLapse;
    address public constant LINK_TOKEN =
        0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address public Wrapper = 0x5A861794B927983406fCE1D062e00b9368d97Df6;
    enum LotteryStatus {
        active,
        finalized,
        refund
    }

    struct LotteryRound {
        mapping(address => uint16) entries;
        mapping(address => uint256) userDeposits;
        address[] participants;
        uint256 lotteryEndTime;
        bool lotteryEnded;
        address winner;
        uint256 prizeWon;
        LotteryStatus roundIdStatus;
    }

    struct LotteryDetail {
        uint256 lotteryId;
        uint256 amountWon;
        address winner;
        address[] participants;
        uint256 totalCollection;
        uint256 lotteryEndTime;
    }
    struct RequestStatus {
        uint256 paid;
        bool fulfilled;
        uint256[] randomWords;
    }
    mapping(address => uint256[]) private UserParticipation;
    mapping(uint256 => LotteryRound) public LotteryRoundInfo;
    mapping(uint256 => RequestStatus) private randomRequestStatus;
    mapping(uint256 => uint256) private requestIds;
    event LotteryEntry(uint256 lotteryId, address participant, uint256 amount);
    event WinnerSelection(uint256 lotteryId, address winner, uint256 amount);
    event PlatfromFeeSent(uint256 lotteryId, uint256 amount);
    event EtherReceived(address sender, uint256 amount);
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 payment
    );

    constructor()
        ConfirmedOwner(msg.sender)
        VRFV2WrapperConsumerBase(LINK_TOKEN, Wrapper)
    {
        platformShare = 10;
        bondPrice = 0.033 * 10**18;
        lotteryDuration = 30 minutes;
        minBalanceCheck = 1000 * 10**18;
        minTimeLapse = 1 minutes;
    }

    error InSufficientEthSent(uint256 required, uint256 sent);
    error requestNotFound();
    error LotteryNotEnded();
    error InsufficientLinkBalance();
    error payoutToWinnerError();
    error payoutToPlatformError();
    error zeroValue();
    error invalidIds();
    error zeroAddress();
    error maxLimitError();
    error refundError();
    error alreadyFinalized();

    receive() external payable {
        if (msg.value < bondPrice) {
            revert InSufficientEthSent(bondPrice, msg.value);
        }
        if (
            block.timestamp >=
            LotteryRoundInfo[lotteryRoundId].lotteryEndTime &&
            !LotteryRoundInfo[lotteryRoundId].lotteryEnded &&
            LotteryRoundInfo[lotteryRoundId].roundIdStatus ==
            LotteryStatus.active
        ) {
            endLotteryInternal();
            unchecked {
                lotteryRoundId++;
                LotteryRoundInfo[lotteryRoundId].lotteryEndTime =
                    block.timestamp +
                    lotteryDuration;
                LotteryRoundInfo[lotteryRoundId].roundIdStatus = LotteryStatus
                    .active;
            }
        }
        if (LotteryRoundInfo[lotteryRoundId].entries[msg.sender] == 0) {
            LotteryRoundInfo[lotteryRoundId].participants.push(msg.sender);
        }
        uint16 entryAmount = uint16(msg.value / bondPrice);
        if (address(platformToken) != address(0)) {
            uint256 userBalance = platformToken.balanceOf(msg.sender);
            if (userBalance >= minBalanceCheck) {
                uint16 additionalEntries = uint16(
                    userBalance / minBalanceCheck
                );
                entryAmount += additionalEntries;
            }
        }

        unchecked {
            LotteryRoundInfo[lotteryRoundId].entries[msg.sender] += entryAmount;
            LotteryRoundInfo[lotteryRoundId].userDeposits[msg.sender] += msg
                .value;
        }
        UserParticipation[msg.sender].push(lotteryRoundId);
        emit LotteryEntry(lotteryRoundId, msg.sender, msg.value);
    }

    function endLottery() external {
        if (
            block.timestamp < LotteryRoundInfo[lotteryRoundId].lotteryEndTime &&
            !LotteryRoundInfo[lotteryRoundId].lotteryEnded
        ) {
            revert LotteryNotEnded();
        }
        endLotteryInternal();
        unchecked {
            lotteryRoundId++;
            LotteryRoundInfo[lotteryRoundId].lotteryEndTime =
                block.timestamp +
                lotteryDuration;
        }
    }

    function endLotteryInternal() internal {
        if (LotteryRoundInfo[lotteryRoundId].participants.length == 0) {
            LotteryRoundInfo[lotteryRoundId].lotteryEnded = true;
            LotteryRoundInfo[lotteryRoundId].roundIdStatus = LotteryStatus
                .finalized;
        } else if (LotteryRoundInfo[lotteryRoundId].participants.length == 1) {
            uint256 totalCollection = LotteryRoundInfo[lotteryRoundId]
                .userDeposits[LotteryRoundInfo[lotteryRoundId].participants[0]];
            address winner = LotteryRoundInfo[lotteryRoundId].participants[0];
            executeWinner(lotteryRoundId, totalCollection, winner);
            LotteryRoundInfo[lotteryRoundId].lotteryEnded = true;
            LotteryRoundInfo[lotteryRoundId].roundIdStatus = LotteryStatus
                .finalized;
        } else {
            requestRandomWords(lotteryRoundId);
            LotteryRoundInfo[lotteryRoundId].lotteryEnded = true;
        }
    }

    function executeWinner(
        uint256 _lotteryId,
        uint256 _amount,
        address _winner
    ) internal {
        uint256 platfromAmount = (_amount * platformShare) / 100;

        uint256 prizeMoney = _amount - platfromAmount;

        (bool payoutToWinnerSuccess, ) = payable(_winner).call{
            value: prizeMoney
        }("");
        if (!payoutToWinnerSuccess) {
            revert payoutToWinnerError();
        }
        (bool payoutToPlatformSuccess, ) = payable(owner()).call{
            value: platfromAmount
        }("");

        if (!payoutToPlatformSuccess) {
            revert payoutToPlatformError();
        }
        LotteryRoundInfo[_lotteryId].winner = _winner;
        LotteryRoundInfo[_lotteryId].prizeWon = prizeMoney;
        emit WinnerSelection(_lotteryId, _winner, prizeMoney);
        emit PlatfromFeeSent(_lotteryId, platfromAmount);
    }

    function lotteryDetail(uint256 startId, uint256 toId)
        external
        view
        returns (LotteryDetail[] memory)
    {
        if (startId == 0 || toId > lotteryRoundId || toId < startId) {
            revert invalidIds();
        }
        LotteryDetail[] memory lotteryData = new LotteryDetail[](
            toId - startId + 1
        );

        uint256 index = 0;
        for (uint256 j = startId; j <= toId; j++) {
            LotteryRound storage round = LotteryRoundInfo[j];
            uint256 totalRoundCollection;
            for (uint16 i; i < LotteryRoundInfo[j].participants.length; ) {
                unchecked {
                    totalRoundCollection += LotteryRoundInfo[j].userDeposits[
                        LotteryRoundInfo[j].participants[i]
                    ];
                    i++;
                }
            }
            lotteryData[index].lotteryId = j;
            lotteryData[index].amountWon = round.prizeWon;
            lotteryData[index].winner = round.winner;
            lotteryData[index].participants = round.participants;
            lotteryData[index].lotteryEndTime = round.lotteryEndTime;
            lotteryData[index].totalCollection = totalRoundCollection;
            index++;
        }
        return lotteryData;
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        if (randomRequestStatus[_requestId].paid == 0) {
            revert requestNotFound();
        }
        randomRequestStatus[_requestId].fulfilled = true;
        randomRequestStatus[_requestId].randomWords = _randomWords;
        uint256 totalEntries;
        uint256 lotteryId = lotteryRoundId - 1;
        uint256 noOfParticipants = LotteryRoundInfo[lotteryId]
            .participants
            .length;
        for (uint16 i; i < noOfParticipants; ) {
            unchecked {
                totalEntries += LotteryRoundInfo[lotteryId].entries[
                    LotteryRoundInfo[lotteryId].participants[i]
                ];
                i++;
            }
        }

        uint256 winningPoint = _randomWords[0] % totalEntries;
        uint256 counter;
        address winner;

        for (uint16 i; i < noOfParticipants; ) {
            unchecked {
                counter += LotteryRoundInfo[lotteryId].entries[
                    LotteryRoundInfo[lotteryId].participants[i]
                ];
                i++;
            }
            if (counter >= winningPoint) {
                winner = LotteryRoundInfo[lotteryId].participants[i];
                break;
            }
        }
        uint256 totalRoundCollection;
        for (uint16 i; i < noOfParticipants; ) {
            unchecked {
                totalRoundCollection += LotteryRoundInfo[lotteryId]
                    .userDeposits[LotteryRoundInfo[lotteryId].participants[i]];
                i++;
            }
        }
        LotteryRoundInfo[lotteryId].roundIdStatus = LotteryStatus.finalized;

        executeWinner(lotteryId, totalRoundCollection, winner);

        emit RequestFulfilled(
            _requestId,
            _randomWords,
            randomRequestStatus[_requestId].paid
        );
    }

    function requestRandomWords(uint256 lotteryId)
        internal
        returns (uint256 requestId)
    {
        requestId = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords
        );
        randomRequestStatus[requestId] = RequestStatus({
            paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
            randomWords: new uint256[](0),
            fulfilled: false
        });
        requestIds[lotteryId] = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    function refundLotteryDeposits(uint256 lotteryId) external {
        if (lotteryId == 0 || lotteryId > lotteryRoundId) {
            revert invalidIds();
        }
        if (
            block.timestamp <
            LotteryRoundInfo[lotteryRoundId].lotteryEndTime + minTimeLapse &&
            !LotteryRoundInfo[lotteryRoundId].lotteryEnded
        ) {
            revert LotteryNotEnded();
        }
        if (
            LotteryRoundInfo[lotteryId].roundIdStatus == LotteryStatus.finalized
        ) {
            revert alreadyFinalized();
        }

        uint256 noOfParticipants = LotteryRoundInfo[lotteryId]
            .participants
            .length;
        for (uint16 i; i < noOfParticipants; ) {
            address user = LotteryRoundInfo[lotteryId].participants[i];
            uint256 amount = LotteryRoundInfo[lotteryId].userDeposits[user];
            (bool succcess, ) = payable(user).call{value: amount}("");

            if (!succcess) {
                revert refundError();
            }
            unchecked {
                i++;
            }
        }
        LotteryRoundInfo[lotteryId].roundIdStatus = LotteryStatus.refund;
        LotteryRoundInfo[lotteryId].lotteryEnded = true;
    }

    function setMinTimeLapse(uint256 newMinTimeLapse) external onlyOwner {
        if (newMinTimeLapse == 0) {
            revert zeroValue();
        }
        minTimeLapse = newMinTimeLapse;
    }

    function setPlatformShare(uint8 _platformShare) external onlyOwner {
        if (_platformShare == 0) {
            revert zeroValue();
        }
        if (_platformShare > 20) {
            revert maxLimitError();
        }

        platformShare = _platformShare;
    }

    function setBalanceThreshold(uint256 _amount) external onlyOwner {
        if (_amount == 0) {
            revert zeroValue();
        }
        minBalanceCheck = _amount;
    }

    function setBondPrice(uint256 _bondPrice) external onlyOwner {
        if (_bondPrice == 0) {
            revert zeroValue();
        }
        bondPrice = _bondPrice;
    }

    function setPlatformToken(address _token) external onlyOwner {
        if (_token == address(0)) {
            revert zeroAddress();
        }
        platformToken = IERC20(_token);
    }

    function setLotteryDuration(uint32 _lotteryDuration) external onlyOwner {
        if (_lotteryDuration == 0) {
            revert zeroValue();
        }
        lotteryDuration = _lotteryDuration;
    }

    function setCallBackGasLimit(uint32 limit) external onlyOwner {
        if (limit == 0) {
            revert zeroValue();
        }
        callbackGasLimit = limit;
    }

    function setRequestConfirmations(uint16 confirmations) external onlyOwner {
        if (confirmations == 0) {
            revert zeroValue();
        }
        requestConfirmations = confirmations;
    }

    function getRequestId(uint256 lotteryId) public view returns (uint256) {
        if (lotteryId == 0 || lotteryId > lotteryRoundId) {
            revert invalidIds();
        }
        return requestIds[lotteryId];
    }

    function getParticipation(address user)
        public
        view
        returns (uint256[] memory)
    {
        return UserParticipation[user];
    }

    function getRequestStatus(uint256 _requestId)
        public
        view
        returns (uint256 randomWords)
    {
        if (randomRequestStatus[_requestId].paid == 0) {
            revert requestNotFound();
        }
        RequestStatus memory request = randomRequestStatus[_requestId];
        return request.randomWords[0];
    }

    function getLotteryPartcipants(uint256 _lotteryId)
        external
        view
        returns (address[] memory participants)
    {
        return LotteryRoundInfo[_lotteryId].participants;
    }

    function getLotteryPartcipantEntries(uint256 _lotteryId, address _user)
        external
        view
        returns (uint256)
    {
        return LotteryRoundInfo[_lotteryId].entries[_user];
    }

    function getLotteryPartcipantDeposits(uint256 lotteryId, address user)
        external
        view
        returns (uint256)
    {
        return LotteryRoundInfo[lotteryId].userDeposits[user];
    }

    function transferLinkToOwner() public onlyOwner {
        uint256 linkBalance = IERC20(LINK_TOKEN).balanceOf(address(this));
        IERC20(LINK_TOKEN).safeTransfer(owner(), linkBalance);
    }
}
