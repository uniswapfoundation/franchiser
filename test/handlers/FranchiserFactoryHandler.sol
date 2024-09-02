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

    // Struct for tracking the number of calls to each handler function
    struct CallCounts {
        uint256 calls;
    }

    // Handler ghost mapping to track the number of calls to each handler function
    mapping(bytes32 => CallCounts) public calls;

    // Handler-updated booleans to track balance and voting power updates were correctly calculated
    bool public balances_updated_correctly;
    bool public voting_powers_updated_correctly;

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

    // Handler ghost array to contain all the franchisers created by the last call to franchiser_subDelegateMany
    Franchiser[] private lastSubDelegatedFranchisersArray;

    // Franchiser that performed the last sub-delegation
    Franchiser private lastSubDelegatingFranchiser;

    constructor(FranchiserFactory _factory) {
        factory = _factory;
        votingToken = VotingTokenConcrete(address(factory.votingToken()));
        franchiser = new Franchiser(IVotingToken(address(votingToken)));
        balances_updated_correctly = true;
        voting_powers_updated_correctly = true;
    }

    modifier countCall(bytes32 key) {
        calls[key].calls++;
        _;
    }

    function _validActorAddress(address _address) internal view returns (bool valid) {
        valid = (_address != address(0))
            && (
                _address != address(votingToken) && (_address != address(factory))
                    && (!fundedFranchisers.contains(_address)
                    && (!subDelegatedFranchisers.contains(_address)))
            );
    }

    function _boundAmount(uint256 _amount) internal pure returns (uint256) {
        return bound(_amount, 0, 100_000_000e18);
    }

    // function to get the amount of voting power held by a franchiser for a given delegator and delegatee
    // (used to get balance of a franchiser via pre-calculated address that may have been deployed previously)
    function _getAmountInFranchiserGivenDelegatorAndDelegatee(address _delegator, address _delegatee) internal view returns (uint256) {
        Franchiser _franchiser = factory.getFranchiser(_delegator, _delegatee);
        return votingToken.balanceOf(address(_franchiser));
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

    // function to get total voting power delegated to the all of delegatees in the delegatees AddressSet
    function _getTotalVotingPowerOfAllDelegatees() internal view returns (uint256 totalVotingPower) {
        totalVotingPower = 0;
        for (uint256 i = 0; i < delegatees.length(); i++) {
            totalVotingPower += votingToken.getVotes(delegatees.at(i));
        }
    }

    // function that takes an array of addresses as a parameter and returns an array with duplicates removed
    function _removeDuplicates(address[] memory _addresses) internal pure returns (address[] memory) {
        if (_addresses.length == 0) {
            return _addresses;
        }
        uint256 _newLength = 1;
        for (uint256 i = 1; i < _addresses.length; i++) {
            bool _isDuplicate = false;
            for (uint256 j = 0; j < _newLength; j++) {
                if (_addresses[i] == _addresses[j]) {
                    _isDuplicate = true;
                    break;
                }
            }
            if (!_isDuplicate) {
                _addresses[_newLength] = _addresses[i];
                _newLength++;
            }
        }
        address[] memory _uniqueAddresses = new address[](_newLength);
        for (uint256 k = 0; k < _newLength; k++) {
            _uniqueAddresses[k] = _addresses[k];
        }
        return _uniqueAddresses;
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

    function _selectFranchiserForSubDelegation(
        uint256 _franchiserIndex,
        bool _treeBuildDesired
    ) internal view returns (Franchiser _selectedFranchiser) {
        if (fundedFranchisers.length() == 0) {
            return Franchiser(address(0));
        }
        // sub-delegate from an existing sub-delegatee (if possible and requested) to aid in sub-delegation tree construction
        if (_treeBuildDesired && (subDelegatedFranchisers.length() > 0)) {
            _franchiserIndex = bound(_franchiserIndex, 0, subDelegatedFranchisers.length() - 1);
            _selectedFranchiser = Franchiser(subDelegatedFranchisers.at(_franchiserIndex));
            console2.log("Sub-delegating from sub-delegated franchiser");
        } else {
            _franchiserIndex = bound(_franchiserIndex, 0, fundedFranchisers.length() - 1);
            _selectedFranchiser = Franchiser(fundedFranchisers.at(_franchiserIndex));
            console2.log("Sub-delegating from funded franchiser");
        }
        if (_selectedFranchiser.subDelegatees().length >= _selectedFranchiser.maximumSubDelegatees()) {
            console2.log("Warning::: Franchiser has reached maximum sub-delegatees");
            return Franchiser(address(0));
        }
        if (votingToken.balanceOf(address(_selectedFranchiser)) == 0) {
            console2.log("Warning::: Franchiser to subdelegate has no token balance");
            return Franchiser(address(0));
        }
    }

    // Invariant Handler functions for FranchiserFactory contract
    function factory_fund(address _delegator, address _delegatee, uint256 _amount) external countCall("factory_fund") {
        vm.assume(_validActorAddress(_delegator));
        _amount = _boundAmount(_amount);
        votingToken.mint(_delegator, _amount);
        uint256 _delegatorBalanceBefore = votingToken.balanceOf(_delegator);
        uint256 _delegateeVotingPowerBefore = votingToken.getVotes(_delegatee);
        uint256 _totalVotingPowerBefore = _getTotalVotingPowerOfAllDelegatees();
        uint256 _amountInFranchiserBefore = _getAmountInFranchiserGivenDelegatorAndDelegatee(_delegator, _delegatee);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _amount);
        franchiser = factory.fund(_delegatee, _amount);
        vm.stopPrank();

        // check if the balances and voting power were updated correctly
        balances_updated_correctly = (_delegatorBalanceBefore - _amount) == votingToken.balanceOf(_delegator);
        voting_powers_updated_correctly = (_delegateeVotingPowerBefore + _amount) == votingToken.getVotes(_delegatee);

        // add the created franchiser to the fundedFranchisers AddressSet for tracking totals invariants
        fundedFranchisers.add(address(franchiser));

        // add the delegator and delegatee to the delegators and delegatees AddressSets for tracking totals invariants
        delegators.add(_delegator);
        delegatees.add(_delegatee);

        // check if the balances and voting power were updated correctly
        balances_updated_correctly = ((_delegatorBalanceBefore - _amount) == votingToken.balanceOf(_delegator))
                                    && (_amountInFranchiserBefore + _amount) == votingToken.balanceOf(address(franchiser));
        voting_powers_updated_correctly = (_delegateeVotingPowerBefore + _amount) == votingToken.getVotes(_delegatee)
                                         && _totalVotingPowerBefore + _amount == _getTotalVotingPowerOfAllDelegatees();
    }

    function factory_fundMany(address _delegator, address[] memory _rawDelegatees, uint256 _baseAmount)
        external
        countCall("factory_fundMany")
    {
        address[] memory _delegatees = _removeDuplicates(_rawDelegatees);
        uint256 _numberOfDelegatees = _delegatees.length;
        _baseAmount = _boundAmount(_baseAmount);
        vm.assume(_validActorAddress(_delegator));
        uint256[] memory _amountsForFundMany = new uint256[](_numberOfDelegatees);

        uint256[] memory _delegateeVotingPowersBefore = new uint256[](_numberOfDelegatees);
        uint256[] memory _franchiserBalancesBefore = new uint256[](_numberOfDelegatees);
        uint256 _totalAmountToMintAndApprove = 0;
        for (uint256 i = 0; i < _numberOfDelegatees; i++) {
            _delegateeVotingPowersBefore[i] = votingToken.getVotes(_delegatees[i]);
            _franchiserBalancesBefore[i] = _getAmountInFranchiserGivenDelegatorAndDelegatee(_delegator, _delegatees[i]);
            uint256 _amount = _baseAmount + i;
            _amountsForFundMany[i] = _amount;
            _totalAmountToMintAndApprove += _amount;
        }
        votingToken.mint(_delegator, _totalAmountToMintAndApprove);
        uint256 _delegatorBalanceBefore = votingToken.balanceOf(_delegator);
        uint256 _totalVotingPowerBefore = _getTotalVotingPowerOfAllDelegatees();

        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _totalAmountToMintAndApprove);

        // clear the storage of the lastFundedFranchisersArray and create a new one with call to fundMany
        delete lastFundedFranchisersArray;
        lastFundedFranchisersArray = factory.fundMany(_delegatees, _amountsForFundMany);
        vm.stopPrank();

        // add the delegator to the delegators AddressSets for tracking totals invariants
        delegators.add(_delegator);

        // add the created franchisers and the delegatees to their appropriate AddressSets for tracking totals invariants
        for (uint256 i = 0; i < lastFundedFranchisersArray.length; i++) {
            fundedFranchisers.add(address(lastFundedFranchisersArray[i]));
        }
        delegatees.add(_delegatees);

        // check if the balances and voting power were updated correctly
        balances_updated_correctly = (_delegatorBalanceBefore - _totalAmountToMintAndApprove) == votingToken.balanceOf(_delegator);
        voting_powers_updated_correctly = _totalVotingPowerBefore + _totalAmountToMintAndApprove == _getTotalVotingPowerOfAllDelegatees();
        for (uint256 i = 0; i < _numberOfDelegatees; i++) {
            if (votingToken.balanceOf(address(lastFundedFranchisersArray[i])) != (_franchiserBalancesBefore[i] + _amountsForFundMany[i])) {
                balances_updated_correctly = false;
            }
            if ((_delegateeVotingPowersBefore[i] + _amountsForFundMany[i]) != votingToken.getVotes(_delegatees[i])) {
                voting_powers_updated_correctly = false;
            }
        }
    }

    function factory_recall(uint256 _fundedFranchiserIndex) external countCall("factory_recall") {
        if (fundedFranchisers.length() == 0) {
            return;
        }
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _selectedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        address _delegatee = _selectedFranchiser.delegatee();
        address _delegator = _selectedFranchiser.delegator();
        uint256 _delegatorBalanceBefore = votingToken.balanceOf(_delegator);
        uint256 _delegateeVotingPowerBefore = votingToken.getVotes(_delegatee);
        uint256 _totalVotingPowerBefore = _getTotalVotingPowerOfAllDelegatees();

        uint256 _amount = _getTotalAmountDelegatedByFranchiser(address(_selectedFranchiser));
        uint256 _amountInFranchiser = votingToken.balanceOf(address(_selectedFranchiser));

        // recall of delegated funds to the delegator
        vm.prank(_delegator);
        factory.recall(_delegatee, _delegator);

        // check if the balances and voting power were updated correctly
        balances_updated_correctly = (_delegatorBalanceBefore + _amount) == votingToken.balanceOf(_delegator);
        voting_powers_updated_correctly = ((_delegateeVotingPowerBefore - _amountInFranchiser) == votingToken.getVotes(_delegatee))
                                         && _totalVotingPowerBefore - _amount == _getTotalVotingPowerOfAllDelegatees();
    }

    // This function will do a factory recall call for a subset of the last funded franchisers created by the factory (fundMan or permitAndFundMany)
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
        }
        delegatees.add(_delegatees);
    }

    // Invariant Handler functions for Franchiser contract
    function franchiser_subDelegate(
        address _subDelegatee,
        uint256 _franchiserIndex,
        uint256 _subDelegateAmountFraction,
        bool _treeBuildDesired
    ) external countCall("franchiser_subDelegate") {
        Franchiser _selectedFranchiser = _selectFranchiserForSubDelegation(_franchiserIndex, _treeBuildDesired);
        if (address(_selectedFranchiser) == address(0)) {
            return;
        }
        uint256 _amount = votingToken.balanceOf(address(_selectedFranchiser));

        address _delegatee = _selectedFranchiser.delegatee();
        vm.assume(_validActorAddress(_subDelegatee));
        vm.assume(_delegatee != _subDelegatee);
        _subDelegateAmountFraction = bound(_subDelegateAmountFraction, 1, _amount);
        uint256 _subDelegateAmount = _amount / _subDelegateAmountFraction;
        vm.prank(_delegatee);
        Franchiser _subDelegatedFranchiser = _selectedFranchiser.subDelegate(_subDelegatee, _subDelegateAmount);

        // add the subDelegated franchiser to the subDelegatedFranchisers AddressSet so it can be found
        // for use in future subDelegations, prefering subdelegatees for tree creation
        subDelegatedFranchisers.add(address(_subDelegatedFranchiser));

        // add the subDelegatee to the delegatees AddressSet for tracking totals invariants
        delegatees.add(_subDelegatee);
    }

    function franchiser_subDelegateMany(
        address[] memory _subDelegatees,
        uint256 _franchiserIndex,
        bool _treeBuildDesired
    ) external countCall("franchiser_subDelegateMany") {
        uint256 _numberOfDelegatees = _subDelegatees.length;
        Franchiser _selectedFranchiser = _selectFranchiserForSubDelegation(_franchiserIndex, _treeBuildDesired);
        if (address(_selectedFranchiser) == address(0)) {
            return;
        }
        uint256 _amountInFranchiser = votingToken.balanceOf(address(_selectedFranchiser));
        _numberOfDelegatees = bound(_numberOfDelegatees, 1, _selectedFranchiser.maximumSubDelegatees() - 1);

        // calculate the amount to sub-delegate to each sub-delegatee
        // (1 more than number delegatees, to make amount smaller to leave some in the franchiser)
        uint256 _subDelegateAmount = _amountInFranchiser / (_numberOfDelegatees + 1);
        if (_subDelegateAmount == 0) {
            console2.log("Warning::: Sub-delegate amount after split for subDelegateMany is 0, skipping this sub-delegate attempt");
            return;
        }
        address _delegatee = _selectedFranchiser.delegatee();
        uint256[] memory _amountsForSubDelegateMany = new uint256[](_numberOfDelegatees);
        address[] memory _subDelegateesForSubDelegateMany = new address[](_numberOfDelegatees);
        for (uint256 i = 0; i < _numberOfDelegatees; i++) {
            _subDelegateesForSubDelegateMany[i] = _subDelegatees[i];
            _amountsForSubDelegateMany[i] = _subDelegateAmount;
        }

        // clear the storage of the lastSubDelegatedFranchisersArray and create a new one with call to subDelegateMany
        delete lastSubDelegatedFranchisersArray;
        vm.prank(_delegatee);
        lastSubDelegatedFranchisersArray = _selectedFranchiser.subDelegateMany(_subDelegateesForSubDelegateMany, _amountsForSubDelegateMany);
        lastSubDelegatingFranchiser = _selectedFranchiser;

        // add the subDelegated franchisers to the subDelegatedFranchisers AddressSet so they can be found
        // for use in future subDelegations, prefering subdelegatees for tree creation
        for (uint256 j = 0; j < lastSubDelegatedFranchisersArray.length; j++) {
            subDelegatedFranchisers.add(address(lastSubDelegatedFranchisersArray[j]));
        }

        // add the subDelegatees to the delegatees AddressSet for tracking totals invariants
        delegatees.add(_subDelegatees);
    }

    // This function will do recalls only from Franchisers that have sub-delegatees
    function franchiser_unSubDelegate() external countCall("franchiser_unSubDelegate") {
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
        address _delegatee = _selectedFranchiser.delegatee();

        // recall the delegated funds
        vm.prank(_delegatee);
        _selectedFranchiser.unSubDelegate(_delegator);
    }

    // This function will do a franchiser unsubdelegate call for a subset of the last sub-delegated franchisers done by a franchiser
    function franchiser_unSubDelegateMany(uint256 _numberFranchisersToUnSubDelegate) external countCall("franchiser_unSubDelegateMany") {
        if (lastSubDelegatedFranchisersArray.length < 3) {
            delete lastSubDelegatedFranchisersArray;
            return;
        }
        _numberFranchisersToUnSubDelegate = bound(_numberFranchisersToUnSubDelegate, 1, lastSubDelegatedFranchisersArray.length - 1);

        address[] memory _delegateesForUnSubDelegateMany = new address[](_numberFranchisersToUnSubDelegate);

        for (uint256 i = 0; i < _numberFranchisersToUnSubDelegate; i++) {
            Franchiser _franchiser = Franchiser(lastSubDelegatedFranchisersArray[i]);
            _delegateesForUnSubDelegateMany[i] = _franchiser.delegatee();
        }
        vm.prank(lastSubDelegatingFranchiser.delegatee());
        lastSubDelegatingFranchiser.unSubDelegateMany(_delegateesForUnSubDelegateMany);

        // empty the lastFundedFranchisersArray, so factory_recallMany can only be called again after a new factory_fundMany
        delete lastSubDelegatedFranchisersArray;
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

        // recall the delegated funds
        vm.prank(_selectedFranchiser.owner());
        _selectedFranchiser.recall(_delegator);
    }

    // recursive function to get the depth of the sub-delegation tree of a given franchiser
    function _getDeepestSubDelegationTree(Franchiser _fundedFranchiser) internal returns (uint256 depth) {
        depth = 0;
        for (uint256 i = 0; i < _fundedFranchiser.subDelegatees().length; i++) {
            Franchiser _subDelegatedFranchiser = _fundedFranchiser.getFranchiser(_fundedFranchiser.subDelegatees()[i]);
            uint256 _subDepth = _getDeepestSubDelegationTree(_subDelegatedFranchiser);
            if (_subDepth > depth) {
                depth = _subDepth;
            }
        }
        depth++;
    }

    // function to find the depth of the funded franchiser with the deepest sub-delegatee tree
    function calculateDeepestSubDelegationTree() private returns (uint256 deepest) {
        deepest = 0;
        for (uint256 i = 0; i < fundedFranchisers.length(); i++) {
            Franchiser _fundedFranchiser = Franchiser(fundedFranchisers.at(i));
            uint256 _subDelegateCount = _fundedFranchiser.subDelegatees().length;
            if (_subDelegateCount > 0) {
                uint256 _depth = _getDeepestSubDelegationTree(_fundedFranchiser);
                if (_depth > deepest) {
                    deepest = _depth;
                }
            }
        }
    } 

    function callSummary() external {
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
        console2.log("franchiser_unSubDelegate", calls["franchiser_unSubDelegate"].calls);
        console2.log("franchiser_unSubDelegateMany", calls["franchiser_unSubDelegateMany"].calls);
        console2.log("franchiser_recall", calls["franchiser_recall"].calls);
        console2.log("-------------------\n");
        console2.log("Deepest sub-delegation tree depth: %d", calculateDeepestSubDelegationTree());
    }
}
