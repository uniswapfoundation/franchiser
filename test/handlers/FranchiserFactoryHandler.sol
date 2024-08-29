// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test, console2} from "forge-std/Test.sol";
import {EnumerableSet} from "test/helpers/EnumerableSet.sol";
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

    // Handler ghost AddressSet to contain all the funded franchisers created by the FranchiserFactory
    EnumerableSet.AddressSet private fundedFranchisers;

    // Handler ghost AddressSet to contain all of the delegators that were used to fund franchisers
    EnumerableSet.AddressSet private delegators;

    // Handler ghost AddressSet to contain all of the delegatees that were delegated to by handler functions
    EnumerableSet.AddressSet private delegatees;

    // Handler ghost AddressSet to contain all of the Franchisers created by sub-delegation
    EnumerableSet.AddressSet private subDelegatedFranchisers;

    // Handler ghost array to contain all the funded franchisers created by the last call to factory_fundMany
    Franchiser[] private lastFundedFranchisersArray;

    constructor(FranchiserFactory _factory) {
        factory = _factory;
        votingToken = VotingTokenConcrete(address(factory.votingToken()));
        franchiser = new Franchiser(IVotingToken(address(votingToken)));
    }

    modifier countCall(bytes32 key) {
        calls[key].calls++;
        _;
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
    function _getTotalAmountDelegatedByFranchiser(address _franchiserAddress) internal returns (uint256 totalAmount) {
        Franchiser _franchiser = Franchiser(_franchiserAddress);
        totalAmount = factory.votingToken().balanceOf(address(_franchiser));
        for (uint256 i = 0; i < _franchiser.subDelegatees().length; i++) {
            vm.startPrank(address(_franchiser));
            address _subDelegatedFranchiser = address(_franchiser.getFranchiser(_franchiser.subDelegatees()[i]));
            vm.stopPrank();
            totalAmount +=  _getTotalAmountDelegatedByFranchiser(_subDelegatedFranchiser);
        }
    }

    // function to get a balance for the reduce functions
    function _getAccountBalance(address _account) internal view returns (uint256 balance) {
        balance = votingToken.balanceOf(_account);
    }

    // function to use the EnumerableSet.AddressSet reduce function to get the sum of the total amount delegated by all funded franchisers
    function _reduceFranchiserBalances(
        uint256 acc,
        function(address) returns (uint256) func)
        internal returns (uint256)
    {
        return fundedFranchisers.reduce(acc, func);
    }

    // function to use the EnumerableSet.AddressSet reduce function to get the sum of the total amount recalled to delegators by funded franchisers
    function _reduceDelegatorBalances(
        uint256 acc,
        function(address) returns (uint256) func)
        internal returns (uint256)
    {
        return delegators.reduce(acc, func);
    }

    // public function (callable by invariant tests) to get the sum of the total amount delegated by all funded franchisers
    function sumFundedFranchisersBalances() public returns (uint256 sum) {
        sum = _reduceFranchiserBalances(0, _getTotalAmountDelegatedByFranchiser);
    }

    // function to get the sum of all delegatees balances
    function sumDelegatorsBalances() public returns (uint256 sum) {
        sum = _reduceDelegatorBalances(0, _getAccountBalance);
    }

    // Recursive function to get the selected subDelegatee of a given funded franchiser if possible
    function _getDeepestSubDelegateeInTree(Franchiser _fundedFranchiser, uint256 _subDelegateIndex) internal returns (Franchiser _selectedFranchiser) {
        _selectedFranchiser = _fundedFranchiser;
        address[] memory _subDelegatees = _selectedFranchiser.subDelegatees();
        if (_subDelegatees.length > 0) {
            if (_subDelegateIndex >= _subDelegatees.length) {
                _subDelegateIndex = bound(_subDelegateIndex, 0, _subDelegatees.length - 1);
            }
            vm.startPrank(address(_selectedFranchiser));
            _selectedFranchiser = _selectedFranchiser.getFranchiser(_selectedFranchiser.subDelegatees()[_subDelegateIndex]);
            vm.stopPrank();
            _selectedFranchiser = _getDeepestSubDelegateeInTree(_selectedFranchiser, _subDelegateIndex);
        }
    }

    // Invariant Handler functions for FranchiserFactory contract
    function factory_fund(address _delegator, address _delegatee, uint256 _amount) external countCall("factory_fund") {
        vm.assume(_validActorAddress(_delegator));
        _amount = _boundAmount(_amount);
        votingToken.mint(_delegator, _amount);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _amount);
        franchiser = factory.fund(_delegatee, _amount);
        vm.stopPrank();

        // add the created franchiser to the fundedFranchisers AddressSet for tracking totals invariants
        fundedFranchisers.add(address(franchiser));

        // add the delegator and delegatee to the delegators and delegatees AddressSets for tracking totals invariants
        delegators.add(_delegator);
        delegatees.add(_delegatee);
    }

    function factory_fundMany(address _delegator, address[] memory _delegatees, uint256 _baseAmount)
        external
        countCall("factory_fundMany")
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

        // add the delegator to the delegators AddressSets for tracking totals invariants
        delegators.add(_delegator);

        // add the created franchisers and the delegatees to their appropriate AddressSets for tracking totals invariants
        for (uint256 j = 0; j < lastFundedFranchisersArray.length; j++) {
            fundedFranchisers.add(address(lastFundedFranchisersArray[j]));
            delegatees.add(_delegatees[j]);
        }
    }

    function factory_recall(uint256 _fundedFranchiserIndex, uint256 _subDelegateeIndex) external countCall("factory_recall") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _selectedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        _selectedFranchiser = _getDeepestSubDelegateeInTree(_selectedFranchiser, _subDelegateeIndex);
        address _delegatee = _selectedFranchiser.delegatee();
        address _delegator = _selectedFranchiser.delegator();

        // recall of delegated funds to the delegator
        vm.prank(_delegator);
        factory.recall(_delegatee, _delegator);
    }

    function factory_recallMany(uint256 _numberFranchisersToRecall) external countCall("factory_recallMany") {
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
            _targetsForRecallMany[i] = _fundedFranchiser.delegator();
        }
        vm.prank(lastFundedFranchisersArray[0].delegator());
        factory.recallMany(_delegateesForRecallMany, _targetsForRecallMany);

        // empty the lastFundedFranchisersArray, so factory_recallMany can only be called again after a new factory_fundMany
        delete lastFundedFranchisersArray;
    }

    function factory_permitAndFund(uint256 _delegatorPrivateKey, address _delegatee, uint256 _amount)
        external
        countCall("factory_permitAndFund")
    {
        (address _delegator, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) =
            votingToken.getPermitSignature(vm, _delegatorPrivateKey, address(factory), _amount);
        votingToken.mint(_delegator, _amount);
        vm.prank(_delegator);
        franchiser = factory.permitAndFund(_delegatee, _amount, _deadline, _v, _r, _s);

        // add the created franchiser to the fundedFranchisers AddressSet for tracking totals invariants
        fundedFranchisers.add(address(franchiser));

        // add the delegator and delegatee to the delegators and delegatees AddressSets for tracking totals invariants
        delegators.add(_delegator);
        delegatees.add(_delegatee);
    }

    function factory_permitAndFundMany(uint256 _delegatorPrivateKey, address[] memory _delegatees, uint256 _amount)
        external
        countCall("factory_permitAndFundMany")
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

        // add the delegator to the delegators AddressSet for tracking totals invariants
        delegators.add(_delegator);

        // add the created franchisers and delegatees to the appropriate AddressSets for tracking total invariants
        for (uint256 j = 0; j < lastFundedFranchisersArray.length; j++) {
            fundedFranchisers.add(address(lastFundedFranchisersArray[j]));
            delegatees.add(_delegatees[j]);
        }
    }

    // Invariant Handler functions for Franchiser contract
    function franchiser_subDelegate(address _subDelegatee, uint256 _fundedFranchiserIndex, uint256 _subDelegateIndex, uint256 _subDelegateAmountFraction) external countCall("franchiser_subDelegate") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _selectedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        _selectedFranchiser = _getDeepestSubDelegateeInTree(_selectedFranchiser, _subDelegateIndex);
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
        Franchiser _subDelegatedFranchiser = _selectedFranchiser.subDelegate(_subDelegatee, _subDelegateAmount);

        // add the subDelegated franchiser to the subDelegatedFranchisers AddressSet so it can be foound
        // for later removal by unsubDelegate, and for use in future subDelegations, prefering subdelegatees for tree creation
        subDelegatedFranchisers.add(address(_subDelegatedFranchiser));
    }

    function franchiser_subDelegateMany(
        address[] memory _subDelegatees,
        uint256 _fundedFranchiserIndex,
        uint256 _subDelegateIndex
    ) external countCall("franchiser_subDelegateMany") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        uint256 _numberOfDelegatees = _subDelegatees.length;
        if (_numberOfDelegatees == 0) {
            return;
        }
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _selectedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        _selectedFranchiser = _getDeepestSubDelegateeInTree(_selectedFranchiser, _subDelegateIndex);
        _numberOfDelegatees = bound(_numberOfDelegatees, 1, _selectedFranchiser.maximumSubDelegatees() - 1);
        uint256 _amountInFranchiser = votingToken.balanceOf(address(_selectedFranchiser));
        if (_amountInFranchiser == 0) {
            return;
        }

        address _delegatee = _selectedFranchiser.delegatee();
        uint256 _subDelegateAmount = _amountInFranchiser / (_numberOfDelegatees + 1);
        if (_subDelegateAmount == 0) {
            return;
        }
        uint256[] memory _amountsForSubDelegateMany = new uint256[](_numberOfDelegatees);
        address[] memory _subDelegateesForSubDelegateMany = new address[](_numberOfDelegatees);
        for (uint256 i = 0; i < _numberOfDelegatees; i++) {
            _subDelegateesForSubDelegateMany[i] = _subDelegatees[i];
            _amountsForSubDelegateMany[i] = _subDelegateAmount;
        }
        vm.prank(_delegatee);
        Franchiser[] memory _subDelegatedFranchisers = _selectedFranchiser.subDelegateMany(_subDelegateesForSubDelegateMany, _amountsForSubDelegateMany);

        // add the subDelegated franchisers to the subDelegatedFranchisers AddressSet so they can be found
        // for later removal by unsubDelegate, and for use in future subDelegations, prefering subdelegatees for tree creation
        for (uint256 j = 0; j < _subDelegatedFranchisers.length; j++) {
            subDelegatedFranchisers.add(address(_subDelegatedFranchisers[j]));
        }
    }

    // This function will do recalls only from Franchisers that have sub-delegatees
    function franchiser_recall() external countCall("franchiser_recall") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        // find a funded franchiser that has sub-delegatees
        uint256 _subDelegateCount = 0;
        uint256 _fundedFranchiserIndex = 0;
        while ( (_fundedFranchiserIndex < fundedFranchisers.length()) && (_subDelegateCount == 0)) {
            _subDelegateCount = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex)).subDelegatees().length;
            if (_subDelegateCount == 0) _fundedFranchiserIndex++;
        }
        if (_subDelegateCount == 0) {
            return;
        }
        Franchiser _selectedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        address _delegator = _selectedFranchiser.delegator();
        // uint256 _amount = _getTotalAmountDelegatedByFranchiser(address(_selectedFranchiser));

        // recall the delegated funds
        vm.prank(_selectedFranchiser.owner());
        _selectedFranchiser.recall(_delegator);
    }

    function callSummary() external view {
        console2.log("\nCall summary:");
        console2.log("-------------------");
        console2.log("factory_fund", calls["factory_fund"].calls);
        console2.log("factory_fundMany", calls["factory_fundMany"].calls);
        console2.log("factory_recall", calls["factory_recall"].calls);
        console2.log("factory_recallMany", calls["factory_recallMany"].calls);
        console2.log("factory_permitAndFund", calls["factory_permitAndFund"].calls);
        console2.log("factory_permitAndFundMany", calls["factory_permitAndFundMany"].calls);
        console2.log("franchiser_subDelegate", calls["franchiser_subDelegate"].calls);
        console2.log("franchiser_subDelegateMany", calls["franchiser_subDelegateMany"].calls);
        console2.log("franchiser_recall", calls["franchiser_recall"].calls);
        console2.log("-------------------\n");
    }
}
