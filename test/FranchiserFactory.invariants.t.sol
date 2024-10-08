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
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = FranchiserFactoryHandler.factory_fund.selector;
        selectors[1] = FranchiserFactoryHandler.factory_fundMany.selector;
        selectors[2] = FranchiserFactoryHandler.factory_recall.selector;
        selectors[3] = FranchiserFactoryHandler.factory_recallMany.selector;
        selectors[4] = FranchiserFactoryHandler.factory_permitAndFund.selector;
        selectors[5] = FranchiserFactoryHandler.factory_permitAndFundMany.selector;
        selectors[6] = FranchiserFactoryHandler.franchiser_subDelegate.selector;
        selectors[7] = FranchiserFactoryHandler.franchiser_subDelegateMany.selector;
        selectors[8] = FranchiserFactoryHandler.franchiser_unSubDelegate.selector;
        selectors[9] = FranchiserFactoryHandler.franchiser_unSubDelegateMany.selector;
        selectors[10] = FranchiserFactoryHandler.franchiser_recall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_FranchiserFactory_fund_code_size_non_zero() external view {
        assertGt(address(handler.franchiser()).code.length, 0);
    }

    function invariant_Franchiser_subdelegate_code_size_non_zero() external view {
        assertGt(address(handler.subDelegatedFranchiser()).code.length, 0);
    }

    function invariant_Franchisers_and_recalled_balance_sum_matches_total_supply() external {
        handler.callSummary();
        assertEq(
            token.totalSupply(),
            handler.sumDelegatorsBalances() + handler.sumFundedFranchisersBalances()
        );
    }

    function invariant_Total_funded_less_total_recalled_matches_franchisers_totals() external {
        handler.callSummary();
        assertEq(
            handler.ghost_totalFunded() - handler.ghost_totalRecalled(),
            handler.sumFundedFranchisersBalances()
        );
    }

    function invariant_Franchiser_subdelegation_totals_are_correct() external {
        handler.callSummary();
        handler.forEachFundedFranchiserAddress(this.assertFundedFranchisersSubDelegationBalancesAreCorrect);
    }

    // Used to see distribution of non-reverting calls
    function invariant_callSummary() public {
        handler.callSummary();
    }

    function assertFundedFranchisersSubDelegationBalancesAreCorrect(address _franchiser) external {
        assertEq(handler.getTotalAmountDelegatedByFranchiser(_franchiser), handler.ghost_fundedFranchiserBalances(_franchiser));
    }
}
