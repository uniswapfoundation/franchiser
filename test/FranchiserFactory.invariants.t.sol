// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test, console2} from "forge-std/Test.sol";
import {IVotingToken} from "src/interfaces/IVotingToken.sol";
import {FranchiserFactory} from "src/FranchiserFactory.sol";
import {FranchiserFactoryHandler} from "test/handlers/FranchiserFactoryHandler.sol";
import {VotingTokenConcrete} from "./VotingTokenConcrete.sol";

contract FranchiseFactoryInvariantTest is Test {
    FranchiserFactory factory;
    FranchiserFactoryHandler handler;
    VotingTokenConcrete token;

    function setUp() public virtual {
        token = new VotingTokenConcrete();
        factory = new FranchiserFactory(IVotingToken(address(token)));
        handler = new FranchiserFactoryHandler(factory);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = FranchiserFactoryHandler.handler_fundMany.selector;
        selectors[1] = FranchiserFactoryHandler.handler_recallMany.selector;
        selectors[2] = FranchiserFactoryHandler.handler_recall.selector;
        selectors[3] = FranchiserFactoryHandler.handler_fund.selector;
        selectors[4] = FranchiserFactoryHandler.handler_permitAndFund.selector;
        selectors[5] = FranchiserFactoryHandler.handler_permitAndFundMany.selector;
        selectors[6] = FranchiserFactoryHandler.handler_subDelegate.selector;
        selectors[7] = FranchiserFactoryHandler.handler_subDelegateMany.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_Franchiser_code_size_non_zero() external view {
        assertGt(address(handler.franchiser()).code.length, 0);
    }

    function invariant_Franchisers_and_recalled_balance_sum_matches_total_supply() external {
        handler.callSummary();
        assertEq(
            token.totalSupply(),
            token.balanceOf(handler.targetAddressForRecalledFunds()) + handler.sumFundedFranchisersBalances()
        );
    }

    // Used to see distribution of non-reverting calls
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
