// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test, console2} from "forge-std/Test.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {VotingTokenConcrete} from "test/VotingTokenConcrete.sol";
import {FranchiserFactory} from "src/FranchiserFactory.sol";
import {Franchiser} from "src/Franchiser.sol";

contract FranchiserFactoryHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    FranchiserFactory public factory;
    Franchiser public franchiser;

    mapping(bytes32 => uint256) public calls;

    // Handler ghost AddressSet to contain all the funded franchisers created by handler_fund
    EnumerableSet.AddressSet private fundedFranchisers;

    // Handler ghost array to contain all the funded franchisers created by the last call to handler_fundMany
    Franchiser[] private lastFundedFranchisersArray;

    // Ghost variable address to receive of the total amount of funds recalled from franchisers
    address public targetAddressForRecalledFunds = makeAddr("targetAddressForRecalledFunds");
    FranchiserFactory public factory;
    Franchiser public franchiser;

    // Handler ghost array to contain all the funded franchisers created by handler_fund
    Franchiser[] public fundedFranchisers;

    constructor(FranchiserFactory _factory) {
        factory = _factory;
        franchiser = new Franchiser(IVotingToken(address(factory.votingToken())));
    }

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    function sumFundedFranchisersBalances() public view returns (uint256 sum) {
        for (uint256 i = 0; i < fundedFranchisers.length(); i++) {
            sum += factory.votingToken().balanceOf(fundedFranchisers.at(i));
        }
    }

    function _validActorAddress(address _address) internal view returns (bool valid) {
        valid = (_address != address(0))
            && (
                _address != address(factory.votingToken()) && (_address != address(factory))
                    && (!fundedFranchisers.contains(_address))
            );
    }

    function _boundAmount(uint256 _amount) internal pure returns (uint256) {
        return bound(_amount, 0, 100_000_000e18);
    }

    function handler_fund(address _delegator, address _delegatee, uint256 _amount) external countCall("handler_fund") {
        vm.assume(_validActorAddress(_delegator));
        _amount = _boundAmount(_amount);
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        votingToken.mint(_delegator, _amount);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _amount);
        franchiser = factory.fund(_delegatee, _amount);
        vm.stopPrank();
        fundedFranchisers.add(address(franchiser));
    }

    function handler_fundMany(address _delegator, uint8 _numberOfDelegatees, uint256 _baseAmount)
        external
        countCall("handler_fundMany")
    {
        _numberOfDelegatees = uint8(bound(_numberOfDelegatees, 2, 255));
        _baseAmount = _bound(_baseAmount, 1, 10_000e18);
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        vm.assume(_validActorAddress(_delegator));
        address[] memory _delegateesForFundMany = new address[](_numberOfDelegatees);
        uint256[] memory _amountsForFundMany = new uint256[](_numberOfDelegatees);
        uint256 _totalAmountToMintAndApprove = 0;
        for (uint256 i = 0; i < _numberOfDelegatees; i++) {
            uint256 _amount = _baseAmount + i;
            string memory _delegatee = string(abi.encodePacked("delegatee", i, _baseAmount));
            _delegateesForFundMany[i] = makeAddr(_delegatee);
            _amountsForFundMany[i] = _amount;
            _totalAmountToMintAndApprove += _amount;
        }
        votingToken.mint(_delegator, _totalAmountToMintAndApprove);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _totalAmountToMintAndApprove);

        // clear the storage of the lastFundedFranchisersArray and create a new one with call to fundMany
        delete lastFundedFranchisersArray;
        lastFundedFranchisersArray = factory.fundMany(_delegateesForFundMany, _amountsForFundMany);
        vm.stopPrank();

        // add the created franchisers to the fundedFranchisers AddressSet for tracking totals invariants
        for (uint256 j = 0; j < lastFundedFranchisersArray.length; j++) {
            fundedFranchisers.add(address(lastFundedFranchisersArray[j]));
        }
    }

    function handler_recall(uint256 _fundedFranchiserIndex) external countCall("handler_recall") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _fundedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        address _delegatee = _fundedFranchiser.delegatee();
        address _delegator = _fundedFranchiser.delegator();
        uint256 _amount = votingToken.balanceOf(address(_fundedFranchiser));

        // do the recall of delegated funds then move the recalled funds to the targetAddressForRecalledFunds
        vm.startPrank(_delegator);
        factory.recall(_delegatee, _delegator);
        votingToken.transfer(targetAddressForRecalledFunds, _amount);
        vm.stopPrank();

        // remove the franchiser from the fundedFranchisers array
        fundedFranchisers.remove(address(_fundedFranchiser));
    }

    function handler_recallMany(uint256 _numberFranchisersToRecall) external countCall("handler_recallMany") {
        if (lastFundedFranchisersArray.length < 3) {
            delete lastFundedFranchisersArray;
            return;
        }
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        _numberFranchisersToRecall = bound(_numberFranchisersToRecall, 1, lastFundedFranchisersArray.length - 1);

        address[] memory _delegateesForRecallMany = new address[](_numberFranchisersToRecall);
        address[] memory _targetsForRecallMany = new address[](_numberFranchisersToRecall);
        uint256[] memory _amountsForRecallMany = new uint256[](_numberFranchisersToRecall);
        uint256 _totalAmountToRecall = 0;

        for (uint256 i = 0; i < _numberFranchisersToRecall; i++) {
            Franchiser _fundedFranchiser = Franchiser(lastFundedFranchisersArray[i]);
            _delegateesForRecallMany[i] = _fundedFranchiser.delegatee();
            _targetsForRecallMany[i] = targetAddressForRecalledFunds;
            uint256 _amount = votingToken.balanceOf(address(_fundedFranchiser));
            _amountsForRecallMany[i] = _amount;
            _totalAmountToRecall += _amount;
            fundedFranchisers.remove(address(lastFundedFranchisersArray[i]));
        }
        vm.prank(lastFundedFranchisersArray[0].delegator());
        factory.recallMany(_delegateesForRecallMany, _targetsForRecallMany);

        // empty the lastFundedFranchisersArray, so handler_recallMany can only be called again after a new handler_fundMany
        delete lastFundedFranchisersArray;
    }

    function callSummary() external view {
        console2.log("\nCall summary:");
        console2.log("-------------------");
        console2.log("handler_fund", calls["handler_fund"]);
        console2.log("handler_fundMany", calls["handler_fundMany"]);
        console2.log("handler_recall", calls["handler_recall"]);
        console2.log("handler_recallMany", calls["handler_recallMany"]);
        console2.log("-------------------\n");
    }
}
