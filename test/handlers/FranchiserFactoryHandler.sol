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

    // Handler ghost array to contain all the funded franchisers created by handler_fund
    Franchiser[] public fundedFranchisers;

    constructor(FranchiserFactory _factory) {
        factory = _factory;
        franchiser = new Franchiser(IVotingToken(address(factory.votingToken())));
    }

    function _validActorAddress(address _address) internal view returns (bool valid) {
        valid =
            (_address != address(0)) && (_address != address(factory.votingToken()) && (_address != address(factory)));
    }

    function _boundAmount(uint256 _amount) internal pure returns (uint256) {
        return bound(_amount, 0, 100000e18);
    }

    function _removeFranchiser(uint256 _index) public {
        require(_index < fundedFranchisers.length, "Index out of bounds");

        for (uint256 i = _index; i < fundedFranchisers.length - 1; i++) {
            fundedFranchisers[i] = fundedFranchisers[i + 1];
        }
        fundedFranchisers.pop();
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
        fundedFranchisers.push(franchiser);
    }

    function handler_recall(uint256 _fundedFranchiserIndex) external {
        _fundedFranchiserIndex = bound(_fundedFranchiserIndex, 0, fundedFranchisers.length - 1);
        Franchiser _fundedFranchiser = fundedFranchisers[_fundedFranchiserIndex];
        address _delegatee = _fundedFranchiser.delegatee();
        address _delegator = _fundedFranchiser.delegator();
        vm.prank(_delegator);
        factory.recall(_delegatee, _delegator);

        // remove the franchiser from the fundedFranchisers array
        _removeFranchiser(_fundedFranchiserIndex);
    }
}
