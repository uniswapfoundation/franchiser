// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import {Test, console2} from "forge-std/Test.sol";
import {IFranchiserFactoryErrors} from "../src/interfaces/FranchiserFactory/IFranchiserFactoryErrors.sol";
import {IFranchiserEvents} from "../src/interfaces/Franchiser/IFranchiserEvents.sol";
import {IFranchiserErrors} from "../src/interfaces/Franchiser/IFranchiserErrors.sol";
import {VotingTokenConcrete} from "./VotingTokenConcrete.sol";
import {IVotingToken} from "../src/interfaces/IVotingToken.sol";
import {FranchiserFactory} from "../src/FranchiserFactory.sol";
import {Franchiser} from "../src/Franchiser.sol";
import {Utils} from "./Utils.sol";

contract FranchiserFactoryTest is Test, IFranchiserFactoryErrors, IFranchiserEvents {
    VotingTokenConcrete private votingToken;
    FranchiserFactory private franchiserFactory;

    function setUp() public {
        votingToken = new VotingTokenConcrete();
        franchiserFactory = new FranchiserFactory(IVotingToken(address(votingToken)));
    }

    function _validActorAddress(address _address) internal view returns (bool valid) {
        valid =
            (_address != address(0)) && (_address != address(votingToken) && (_address != address(franchiserFactory)));
    }

    function _boundAmount(uint256 _amount) internal pure returns (uint256) {
        return bound(_amount, 0, 100_000_000e18);
    }

    function testSetUp() public {
        assertEq(franchiserFactory.INITIAL_MAXIMUM_SUBDELEGATEES(), 8);
        assertEq(
            address(franchiserFactory.franchiserImplementation()),
            address(franchiserFactory.franchiserImplementation().franchiserImplementation())
        );
        assertEq(franchiserFactory.franchiserImplementation().owner(), address(0));
        assertEq(franchiserFactory.franchiserImplementation().delegator(), address(0));
        assertEq(franchiserFactory.franchiserImplementation().delegatee(), address(1));
        assertEq(franchiserFactory.franchiserImplementation().maximumSubDelegatees(), 0);
    }

    function testFundZero() public {
        Franchiser expectedFranchiser = franchiserFactory.getFranchiser(Utils.alice, Utils.bob);

        vm.expectEmit(true, true, true, true, address(expectedFranchiser));
        emit Initialized(address(franchiserFactory), Utils.alice, Utils.bob, 8);
        vm.prank(Utils.alice);
        Franchiser franchiser = franchiserFactory.fund(Utils.bob, 0);

        assertEq(address(expectedFranchiser), address(franchiser));
        assertEq(franchiser.owner(), address(franchiserFactory));
        assertEq(franchiser.delegatee(), Utils.bob);
        assertEq(votingToken.delegates(address(franchiser)), Utils.bob);
    }

    function testFundCanCallTwice() public {
        vm.startPrank(Utils.alice);
        franchiserFactory.fund(Utils.bob, 0);
        franchiserFactory.fund(Utils.bob, 0);
        vm.stopPrank();
    }

    function testFundNonZeroRevertsTRANSFER_FROM_FAILED() public {
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        franchiserFactory.fund(Utils.bob, 100);
    }

    function testFundNonZero() public {
        votingToken.mint(Utils.alice, 100);

        vm.startPrank(Utils.alice);
        votingToken.approve(address(franchiserFactory), 100);
        Franchiser franchiser = franchiserFactory.fund(Utils.bob, 100);
        vm.stopPrank();

        assertEq(votingToken.balanceOf(address(franchiser)), 100);
        assertEq(votingToken.getVotes(Utils.bob), 100);
    }

    function testFuzz_FundBalancesAndVotingPowerUpdated(address _delegator, address _delegatee, uint256 _amount)
        public
    {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_delegatee != address(0));
        _amount = _boundAmount(_amount);
        Franchiser expectedFranchiser = franchiserFactory.getFranchiser(_delegator, _delegatee);
        uint256 _delegateeVotesBefore = votingToken.getVotes(_delegatee);
        uint256 _franchiserBalanceBefore = votingToken.balanceOf(address(expectedFranchiser));

        votingToken.mint(_delegator, _amount);
        uint256 _delegatorBalanceBefore = votingToken.balanceOf(_delegator);

        vm.startPrank(_delegator);
        votingToken.approve(address(franchiserFactory), _amount);
        Franchiser franchiser = franchiserFactory.fund(_delegatee, _amount);
        vm.stopPrank();

        assertEq(votingToken.balanceOf(address(franchiser)), _franchiserBalanceBefore + _amount);
        assertEq(votingToken.getVotes(_delegatee), _delegateeVotesBefore + _amount);
        assertEq(votingToken.balanceOf(_delegator), _delegatorBalanceBefore - _amount);
    }

    function testFuzz_FundFailsWhenDelegateeIsAddressZero(address _delegator, uint256 _amount) public {
        vm.assume(_validActorAddress(_delegator));
        address _delegatee = address(0);
        _amount = _boundAmount(_amount);

        votingToken.mint(_delegator, _amount);

        vm.startPrank(_delegator);
        votingToken.approve(address(franchiserFactory), _amount);
        vm.expectRevert(IFranchiserErrors.NoDelegatee.selector);
        franchiserFactory.fund(_delegatee, _amount);
        vm.stopPrank();
    }

    function testFuzz_RevertIf_BalanceTooLow(address _delegator, address _delegatee, uint256 _amount, uint256 _delta)
        public
    {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_delegatee != address(0));
        vm.assume((_amount >= _delta) && (_amount <= 100_000_000e18));
        _delta = bound(_delta, 1, 100_000_000e18);
        _amount = bound(_amount, _delta, 100_000_000e18);

        votingToken.mint(_delegator, _amount - _delta);

        vm.startPrank(_delegator);
        votingToken.approve(address(franchiserFactory), _amount);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        franchiserFactory.fund(_delegatee, _amount);
        vm.stopPrank();
    }

    function testFundManyRevertsArrayLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 0, 1));
        franchiserFactory.fundMany(new address[](0), new uint256[](1));

        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 0));
        franchiserFactory.fundMany(new address[](1), new uint256[](0));
    }

    function testFundMany() public {
        votingToken.mint(Utils.alice, 100);

        address[] memory delegatees = new address[](2);
        delegatees[0] = Utils.bob;
        delegatees[1] = Utils.carol;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50;
        amounts[1] = 50;

        vm.startPrank(Utils.alice);
        votingToken.approve(address(franchiserFactory), 100);
        Franchiser[] memory franchisers = franchiserFactory.fundMany(delegatees, amounts);
        vm.stopPrank();

        assertEq(votingToken.balanceOf(address(franchisers[0])), 50);
        assertEq(votingToken.balanceOf(address(franchisers[1])), 50);
    }

    function testRecallZero() public {
        franchiserFactory.recall(Utils.bob, Utils.alice);
    }

    function testRecallNonZero() public {
        votingToken.mint(Utils.alice, 100);

        vm.startPrank(Utils.alice);
        votingToken.approve(address(franchiserFactory), 100);
        Franchiser franchiser = franchiserFactory.fund(Utils.bob, 100);
        franchiserFactory.recall(Utils.bob, Utils.alice);
        vm.stopPrank();

        assertEq(votingToken.balanceOf(address(franchiser)), 0);
        assertEq(votingToken.balanceOf(Utils.alice), 100);
        assertEq(votingToken.getVotes(Utils.bob), 0);
    }

    function testFuzz_RecallDelegatorBalanceUpdated(address _delegator, address _delegatee, uint256 _amount) public {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_delegatee != address(0));
        _amount = _boundAmount(_amount);

        votingToken.mint(_delegator, _amount);

        vm.startPrank(_delegator);
        votingToken.approve(address(franchiserFactory), _amount);
        franchiserFactory.fund(_delegatee, _amount);

        uint256 _delegatorBalanceBeforeRecall = votingToken.balanceOf(_delegator);
        franchiserFactory.recall(_delegatee, _delegator);
        vm.stopPrank();

        assertEq(votingToken.balanceOf(_delegator), _delegatorBalanceBeforeRecall + _amount);
    }

    function testRecallManyRevertsArrayLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 0, 1));
        franchiserFactory.recallMany(new address[](0), new address[](1));

        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 0));
        franchiserFactory.recallMany(new address[](1), new address[](0));
    }

    function testRecallMany() public {
        votingToken.mint(Utils.alice, 100);

        address[] memory delegatees = new address[](2);
        delegatees[0] = Utils.bob;
        delegatees[1] = Utils.carol;

        address[] memory tos = new address[](2);
        tos[0] = Utils.alice;
        tos[1] = Utils.alice;

        vm.startPrank(Utils.alice);
        votingToken.approve(address(franchiserFactory), 100);
        franchiserFactory.fund(Utils.bob, 50);
        franchiserFactory.fund(Utils.carol, 50);
        franchiserFactory.recallMany(delegatees, tos);
        vm.stopPrank();

        assertEq(votingToken.balanceOf(Utils.alice), 100);
    }

    function testRecallGasWorstCase() public {
        Utils.nestMaximum(vm, votingToken, franchiserFactory);
        vm.prank(address(1));
        uint256 gasBefore = gasleft();
        franchiserFactory.recall(address(2), address(1));
        uint256 gasUsed = gasBefore - gasleft();
        unchecked {
            assertGt(gasUsed, 2 * 1e6);
            assertLt(gasUsed, 5 * 1e6);
            console2.log(gasUsed);
        }
        assertEq(votingToken.balanceOf(address(1)), 64);
    }

    function testPermitAndFund() public {
        (address owner, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            votingToken.getPermitSignature(vm, 0xa11ce, address(franchiserFactory), 100);
        votingToken.mint(owner, 100);
        vm.prank(owner);
        Franchiser franchiser = franchiserFactory.permitAndFund(Utils.bob, 100, deadline, v, r, s);

        assertEq(votingToken.balanceOf(address(franchiser)), 100);
        assertEq(votingToken.getVotes(Utils.bob), 100);
    }

    function testPermitAndFundManyRevertsArrayLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 0, 1));
        franchiserFactory.permitAndFundMany(new address[](0), new uint256[](1), 0, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 0));
        franchiserFactory.permitAndFundMany(new address[](1), new uint256[](0), 0, 0, 0, 0);
    }

    // fails because of overflow
    function testFailPermitAndFundMany() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = type(uint256).max;
        amounts[1] = 1;

        franchiserFactory.permitAndFundMany(new address[](2), amounts, 0, 0, 0, 0);
    }

    function testPermitAndFundMany() public {
        (address owner, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            votingToken.getPermitSignature(vm, 0xa11ce, address(franchiserFactory), 100);
        votingToken.mint(owner, 100);

        address[] memory delegatees = new address[](2);
        delegatees[0] = Utils.bob;
        delegatees[1] = Utils.carol;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50;
        amounts[1] = 50;

        vm.prank(owner);
        Franchiser[] memory franchisers = franchiserFactory.permitAndFundMany(delegatees, amounts, deadline, v, r, s);

        assertEq(votingToken.balanceOf(address(franchisers[0])), 50);
        assertEq(votingToken.balanceOf(address(franchisers[1])), 50);
    }
}
