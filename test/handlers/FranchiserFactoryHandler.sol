// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test, console2} from "forge-std/Test.sol";

import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {VotingTokenConcrete} from "test/VotingTokenConcrete.sol";
import {FranchiserFactory} from "src/FranchiserFactory.sol";
import {Franchiser} from "src/Franchiser.sol";

contract FranchiserFactoryHandler is Test {
    FranchiserFactory public factory;
    Franchiser public franchiser;

    constructor(FranchiserFactory _factory) {
        factory = _factory;
        franchiser = new Franchiser(IVotingToken(address(factory.votingToken())));
    }

    function validAddress(address _address) internal view returns (bool valid) {
        valid =
            (_address != address(0)) && (_address != address(factory.votingToken()) && (_address != address(factory)));
    }

    function handler_fund(address _delegator, address _delegatee, uint256 _amount) external {
        vm.assume(_delegator != _delegatee);
        vm.assume(validAddress(_delegator));
        vm.assume(validAddress(_delegatee));
        _amount = bound(_amount, 0, 100000);
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        votingToken.mint(_delegator, _amount);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _amount);
        franchiser = factory.fund(_delegatee, _amount);
        vm.stopPrank();
    }

    function handler_recall(address _delegator, address _delegatee, uint256 _amount) external {
        vm.assume(_delegator != _delegatee);
        vm.assume(validAddress(_delegator));
        vm.assume(validAddress(_delegatee));
        _amount = bound(_amount, 0, 100000);
        VotingTokenConcrete votingToken = VotingTokenConcrete(address(factory.votingToken()));
        votingToken.mint(_delegator, _amount);
        vm.startPrank(_delegator);
        votingToken.approve(address(factory), _amount);
        franchiser = factory.fund(_delegatee, _amount);
        factory.recall(_delegatee, _delegator);
        vm.stopPrank();
    }
}
