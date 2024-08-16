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

    // Ghost variable to keep track of amount recalled from funded franchisers
    uint256 public totalRecalledFromFundedFranchisers = 0;

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
        Franchiser[] memory _franchisers = factory.fundMany(_delegateesForFundMany, _amountsForFundMany);
        vm.stopPrank();
        for (uint256 j = 0; j < _franchisers.length; j++) {
            fundedFranchisers.add(address(_franchisers[j]));
        }
    }

    function handler_recall(uint256 _fundedFranchiserIndex) external countCall("handler_recall") {
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _fundedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        address _delegatee = _fundedFranchiser.delegatee();
        address _delegator = _fundedFranchiser.delegator();

        // update the total recalled for checking the balances invariant and
        totalRecalledFromFundedFranchisers += votingToken.balanceOf(address(_fundedFranchiser));

        // do the recall of delegated funds
        vm.prank(_delegator);
        factory.recall(_delegatee, _delegator);

        // remove the franchiser from the fundedFranchisers array
        fundedFranchisers.remove(address(_fundedFranchiser));
    }

    function handler_recallMany(uint256 _numberFranchiersToRecall) external countCall("handler_recallMany") {
        if (fundedFranchisers.length() < 3) {
            return;
        }
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        _numberFranchiersToRecall = bound(_numberFranchiersToRecall, 1, fundedFranchisers.length() - 2);
        address[] memory _delegateesForRecallMany = new address[](_numberFranchiersToRecall);
        address[] memory _delegatorsForRecallMany = new address[](_numberFranchiersToRecall);

        // get the _numberFranchiersToRecall franchisers from the fundedFranchisers array
        for (uint256 i = 0; i < _numberFranchiersToRecall; i++) {
            Franchiser _fundedFranchiser = Franchiser(fundedFranchisers.at(i));
            _delegateesForRecallMany[i] = _fundedFranchiser.delegatee();
            _delegatorsForRecallMany[i] = _fundedFranchiser.delegator();
            fundedFranchisers.remove(address(_fundedFranchiser));
            totalRecalledFromFundedFranchisers += votingToken.balanceOf(address(_fundedFranchiser));
        }
        vm.prank(_delegatorsForRecallMany[0]);
        factory.recallMany(_delegateesForRecallMany, _delegatorsForRecallMany);
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
