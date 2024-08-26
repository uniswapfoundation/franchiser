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
    VotingTokenConcrete public votingToken;

    struct CallCounts {
        uint256 calls;
    }

    mapping(bytes32 => CallCounts) public calls;

    // Handler ghost AddressSet to contain all the funded franchisers created by FranchiserFactory handler_fund
    EnumerableSet.AddressSet private fundedFranchisers;

    // Handler ghost array to contain all the funded franchisers created by the last call to handler_fundMany
    Franchiser[] private lastFundedFranchisersArray;

    // Ghost variable address to receive of the total amount of funds recalled from franchisers
    address public targetAddressForRecalledFunds = makeAddr("targetAddressForRecalledFunds");

    constructor(FranchiserFactory _factory) {
        factory = _factory;
        votingToken = VotingTokenConcrete(address(factory.votingToken()));
        franchiser = new Franchiser(IVotingToken(address(votingToken)));
    }

    modifier countCall(bytes32 key) {
        calls[key].calls++;
        _;
    }

    function sumFundedFranchisersBalances() public returns (uint256 sum) {
        for (uint256 i = 0; i < fundedFranchisers.length(); i++) {
            sum += _getTotalAmountDelegatedByFranchiser(Franchiser(fundedFranchisers.at(i)));
        }
    }

    function _validActorAddress(address _address) internal view returns (bool valid) {
        valid = (_address != address(0))
            && (
                _address != address(votingToken) && (_address != address(factory))
                    && (!fundedFranchisers.contains(_address))
            );
    }

    function _boundAmount(uint256 _amount) internal pure returns (uint256) {
        return bound(_amount, 0, 100_000_000e18);
    }

    // Recursive function to get the sum tokens held in the sub-delegation tree of a given franchiser
    function _getTotalAmountDelegatedByFranchiser(Franchiser _franchiser) internal returns (uint256 totalAmount) {
        totalAmount = factory.votingToken().balanceOf(address(_franchiser));
        for (uint256 i = 0; i < _franchiser.subDelegatees().length; i++) {
            vm.startPrank(address(_franchiser));
            Franchiser _subDelegatedFranchiser = _franchiser.getFranchiser(_franchiser.subDelegatees()[i]);
            vm.stopPrank();
            totalAmount +=  _getTotalAmountDelegatedByFranchiser(_subDelegatedFranchiser);
        }
    }

    // Recursive function to get the selected subDelegatee of a given funded franchiser if possible
    function _getSelectedSubDelegateeIfPossible(Franchiser _fundedFranchiser, uint256 _subDelegateIndex) internal returns (Franchiser _selectedFranchiser) {
        _selectedFranchiser = _fundedFranchiser;
        address[] memory _subDelegatees = _selectedFranchiser.subDelegatees();
        if (_subDelegatees.length > 0) {
            if (_subDelegateIndex >= _subDelegatees.length) {
                _subDelegateIndex = bound(_subDelegateIndex, 0, _subDelegatees.length - 1);
            }
            vm.startPrank(address(_selectedFranchiser));
            _selectedFranchiser = _selectedFranchiser.getFranchiser(_selectedFranchiser.subDelegatees()[_subDelegateIndex]);
            vm.stopPrank();
            _selectedFranchiser = _getSelectedSubDelegateeIfPossible(_selectedFranchiser, _subDelegateIndex);
        }
    }

    // Invariant Handler functions for FranchiserFactory contract
    function handler_fund(address _delegator, address _delegatee, uint256 _amount) external countCall("handler_fund") {
        vm.assume(_validActorAddress(_delegator));
        _amount = _boundAmount(_amount);
        votingToken.mint(_delegator, _amount);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _amount);
        franchiser = factory.fund(_delegatee, _amount);
        vm.stopPrank();
        fundedFranchisers.add(address(franchiser));
    }

    function handler_fundMany(address _delegator, address[] memory _delegatees, uint256 _baseAmount)
        external
        countCall("handler_fundMany")
    {
        uint256 _numberOfDelegatees = _delegatees.length;
        _baseAmount = _boundAmount(_baseAmount);
        vm.assume(_validActorAddress(_delegator));
        uint256[] memory _amountsForFundMany = new uint256[](_numberOfDelegatees);
        uint256 _totalAmountToMintAndApprove = 0;
        for (uint256 i = 0; i < _numberOfDelegatees; i++) {
            uint256 _amount = _baseAmount + i;
            _amountsForFundMany[i] = _amount;
            _totalAmountToMintAndApprove += _amount;
        }
        votingToken.mint(_delegator, _totalAmountToMintAndApprove);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _totalAmountToMintAndApprove);

        // clear the storage of the lastFundedFranchisersArray and create a new one with call to fundMany
        delete lastFundedFranchisersArray;
        lastFundedFranchisersArray = factory.fundMany(_delegatees, _amountsForFundMany);
        vm.stopPrank();

        // add the created franchisers to the fundedFranchisers AddressSet for tracking totals invariants
        for (uint256 j = 0; j < lastFundedFranchisersArray.length; j++) {
            fundedFranchisers.add(address(lastFundedFranchisersArray[j]));
        }
    }

    function handler_recall(uint256 _fundedFranchiserIndex, uint256 _subDelegateeIndex) external countCall("handler_recall") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _selectedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        _selectedFranchiser = _getSelectedSubDelegateeIfPossible(_selectedFranchiser, _subDelegateeIndex);
        address _delegatee = _selectedFranchiser.delegatee();
        address _delegator = _selectedFranchiser.delegator();
        uint256 _amount = _getTotalAmountDelegatedByFranchiser(_selectedFranchiser);

        // recall of delegated funds then move the recalled funds to the targetAddressForRecalledFunds
        vm.startPrank(_delegator);
        factory.recall(_delegatee, _delegator);
        votingToken.transfer(targetAddressForRecalledFunds, _amount);
        vm.stopPrank();

        // remove the franchiser from the fundedFranchisers array
        fundedFranchisers.remove(address(_selectedFranchiser));
    }

    function handler_recallMany(uint256 _numberFranchisersToRecall) external countCall("handler_recallMany") {
        if (lastFundedFranchisersArray.length < 3) {
            delete lastFundedFranchisersArray;
            return;
        }
        _numberFranchisersToRecall = bound(_numberFranchisersToRecall, 1, lastFundedFranchisersArray.length - 1);

        address[] memory _delegateesForRecallMany = new address[](_numberFranchisersToRecall);
        address[] memory _targetsForRecallMany = new address[](_numberFranchisersToRecall);

        for (uint256 i = 0; i < _numberFranchisersToRecall; i++) {
            Franchiser _fundedFranchiser = Franchiser(lastFundedFranchisersArray[i]);
            _delegateesForRecallMany[i] = _fundedFranchiser.delegatee();
            _targetsForRecallMany[i] = targetAddressForRecalledFunds;
            fundedFranchisers.remove(address(lastFundedFranchisersArray[i]));
        }
        vm.prank(lastFundedFranchisersArray[0].delegator());
        factory.recallMany(_delegateesForRecallMany, _targetsForRecallMany);

        // empty the lastFundedFranchisersArray, so handler_recallMany can only be called again after a new handler_fundMany
        delete lastFundedFranchisersArray;
    }

    function handler_permitAndFund(uint256 _delegatorPrivateKey, address _delegatee, uint256 _amount)
        external
        countCall("handler_permitAndFund")
    {
        (address _delegator, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) =
            votingToken.getPermitSignature(vm, _delegatorPrivateKey, address(factory), _amount);
        votingToken.mint(_delegator, _amount);
        vm.prank(_delegator);
        franchiser = factory.permitAndFund(_delegatee, _amount, _deadline, _v, _r, _s);
        fundedFranchisers.add(address(franchiser));
    }

    function handler_permitAndFundMany(uint256 _delegatorPrivateKey, address[] memory _delegatees, uint256 _amount)
        external
        countCall("handler_permitAndFundMany")
    {
        uint256 _numberOfDelegatees = _delegatees.length;
        _amount = _bound(_amount, 1, 10_000e18);
        (address _delegator, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) =
            votingToken.getPermitSignature(vm, _delegatorPrivateKey, address(factory), _amount * _numberOfDelegatees);
        uint256[] memory _amountsForFundMany = new uint256[](_numberOfDelegatees);
        uint256 _totalAmountToMintAndApprove = 0;
        for (uint256 i = 0; i < _numberOfDelegatees; i++) {
            _amountsForFundMany[i] = _amount;
            _totalAmountToMintAndApprove += _amount;
        }
        votingToken.mint(_delegator, _totalAmountToMintAndApprove);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _totalAmountToMintAndApprove);

        // clear the storage of the lastFundedFranchisersArray and create a new one with call to fundMany
        delete lastFundedFranchisersArray;
        lastFundedFranchisersArray = factory.permitAndFundMany(_delegatees, _amountsForFundMany, _deadline, _v, _r, _s);
        vm.stopPrank();

        // add the created franchisers to the fundedFranchisers AddressSet for tracking total invariants
        for (uint256 j = 0; j < lastFundedFranchisersArray.length; j++) {
            fundedFranchisers.add(address(lastFundedFranchisersArray[j]));
        }
    }

    // Invariant Handler functions for Franchiser contract
    function handler_subDelegate(address _subDelegatee, uint256 _fundedFranchiserIndex, uint256 _subDelegateIndex, uint256 _subDelegateAmountFraction) external countCall("handler_subDelegate") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _selectedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        _selectedFranchiser = _getSelectedSubDelegateeIfPossible(_selectedFranchiser, _subDelegateIndex);
        uint256 _amount = votingToken.balanceOf(address(_selectedFranchiser));
        if (_amount == 0) {
            return;
        }
        address _delegatee = _selectedFranchiser.delegatee();
        vm.assume(_validActorAddress(_subDelegatee));
        vm.assume(_delegatee != _subDelegatee);
        _subDelegateAmountFraction = bound(_subDelegateAmountFraction, 1, _amount);
        uint256 _subDelegateAmount = _amount / _subDelegateAmountFraction;
        vm.prank(_delegatee);
        _selectedFranchiser.subDelegate(_subDelegatee, _subDelegateAmount);
    }

    function callSummary() external view {
        console2.log("\nCall summary:");
        console2.log("-------------------");
        console2.log("handler_fund", calls["handler_fund"].calls);
        console2.log("handler_fundMany", calls["handler_fundMany"].calls);
        console2.log("handler_recall", calls["handler_recall"].calls);
        console2.log("handler_recallMany", calls["handler_recallMany"].calls);
        console2.log("handler_permitAndFund", calls["handler_permitAndFund"].calls);
        console2.log("handler_permitAndFundMany", calls["handler_permitAndFundMany"].calls);
        console2.log("handler_subDelegate", calls["handler_subDelegate"].calls);
        console2.log("-------------------\n");
    }
}
