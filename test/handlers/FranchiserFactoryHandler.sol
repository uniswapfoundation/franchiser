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

    // Handler ghost AddressSet to contain all the funded franchisers created by handler_fund
    EnumerableSet.AddressSet private fundedFranchisers;

    // Handler ghost AddressSet to contain all of the delegators that have recalled their franchisers
    EnumerableSet.AddressSet private recalledDelegators;

    constructor(FranchiserFactory _factory) {
        factory = _factory;
        franchiser = new Franchiser(IVotingToken(address(factory.votingToken())));
    }

    function sumRecalledDelegatorsBalances() public view returns (uint256 sum) {
        sum = 0;
        for (uint256 i = 0; i < recalledDelegators.length(); i++) {
            sum += factory.votingToken().balanceOf(recalledDelegators.at(i));
        }
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

    function handler_fund(address _delegator, address _delegatee, uint256 _amount) external {
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

    function handler_recall(uint256 _fundedFranchiserIndex) external {
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length() - 1);
        Franchiser _fundedFranchiser = Franchiser(fundedFranchisers.at(_fundedFranchiserIndex));
        address _delegatee = _fundedFranchiser.delegatee();
        address _delegator = _fundedFranchiser.delegator();
        vm.prank(_delegator);
        factory.recall(_delegatee, _delegator);

        // remove the franchiser from the fundedFranchisers array and save the delegator so we can check the balances invariant
        fundedFranchisers.remove(address(_fundedFranchiser));
        recalledDelegators.add(_delegator);
    }
}
