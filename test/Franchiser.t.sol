// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {IFranchiserErrors} from "../src/interfaces/Franchiser/IFranchiserErrors.sol";
import {IFranchiserEvents} from "../src/interfaces/Franchiser/IFranchiserEvents.sol";
import {VotingTokenConcrete} from "./VotingTokenConcrete.sol";
import {Franchiser} from "../src/Franchiser.sol";
import {IVotingToken} from "../src/interfaces/IVotingToken.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Utils} from "./Utils.sol";

contract FranchiserTest is Test, IFranchiserErrors, IFranchiserEvents {
    using Clones for address;

    VotingTokenConcrete private votingToken;
    Franchiser private franchiserImplementation;
    Franchiser private franchiser;

    function _validActorAddress(address _address) internal view returns (bool valid) {
        valid = (_address != address(0)) && (_address != address(votingToken));
    }

    function _boundAmount(uint256 _amount) internal pure returns (uint256) {
        return bound(_amount, 0, 100_000_000e18);
    }

    function setUp() public {
        votingToken = new VotingTokenConcrete();
        franchiserImplementation = new Franchiser(IVotingToken(address(votingToken)));
        // we need to set this up as a clone to work
        franchiser = Franchiser(address(franchiserImplementation).clone());
    }

    function testSetUp() public {
        assertEq(franchiserImplementation.DECAY_FACTOR(), 2);
        assertEq(address(franchiserImplementation.franchiserImplementation()), address(franchiserImplementation));
        assertEq(franchiserImplementation.owner(), address(0));
        assertEq(franchiserImplementation.delegator(), address(0));
        assertEq(franchiserImplementation.delegatee(), address(1));
        assertEq(franchiserImplementation.maximumSubDelegatees(), 0);
        assertEq(franchiserImplementation.subDelegatees(), new address[](0));

        assertEq(franchiser.DECAY_FACTOR(), 2);
        assertEq(address(franchiser.franchiserImplementation()), address(franchiserImplementation));
        assertEq(franchiser.owner(), address(0));
        assertEq(franchiser.delegator(), address(0));
        assertEq(franchiser.delegatee(), address(0));
        assertEq(franchiser.maximumSubDelegatees(), 0);
        assertEq(franchiser.subDelegatees(), new address[](0));
    }

    function testInitializeRevertsNoDelegatee() public {
        vm.expectRevert(NoDelegatee.selector);
        franchiser.initialize(address(0), 0);
        vm.expectRevert(NoDelegatee.selector);
        franchiser.initialize(Utils.alice, address(0), 0);
    }

    function testInitialize() public {
        vm.expectEmit(true, true, false, true, address(franchiser));
        emit Initialized(address(1), Utils.alice, Utils.bob, 1);
        vm.prank(address(1));
        franchiser.initialize(Utils.alice, Utils.bob, 1);

        assertEq(franchiser.owner(), address(1));
        assertEq(franchiser.delegator(), Utils.alice);
        assertEq(franchiser.delegatee(), Utils.bob);
        assertEq(franchiser.maximumSubDelegatees(), 1);
        assertEq(votingToken.delegates(address(franchiser)), Utils.bob);
    }

    function testInitializeNoDelegator() public {
        vm.expectEmit(true, true, false, true, address(franchiser));
        emit Initialized(address(1), address(0), Utils.bob, 1);
        vm.mockCall(address(1), abi.encodeWithSignature("delegatee()"), abi.encode(address(0)));
        vm.prank(address(1));
        franchiser.initialize(Utils.bob, 1);

        assertEq(franchiser.owner(), address(1));
        assertEq(franchiser.delegator(), address(0));
        assertEq(franchiser.delegatee(), Utils.bob);
        assertEq(franchiser.maximumSubDelegatees(), 1);
        assertEq(votingToken.delegates(address(franchiser)), Utils.bob);
    }

    function testInitializeRevertsAlreadyInitialized() public {
        franchiser.initialize(Utils.alice, Utils.bob, 0);
        vm.expectRevert(AlreadyInitialized.selector);
        franchiser.initialize(Utils.alice, Utils.bob, 0);
        vm.expectRevert(AlreadyInitialized.selector);
        franchiser.initialize(Utils.bob, 0);
    }

    function testInitializeRevertsAlreadyInitializedNoDelegator() public {
        vm.mockCall(address(1), abi.encodeWithSignature("delegatee()"), abi.encode(address(0)));
        vm.prank(address(1));
        franchiser.initialize(Utils.bob, 0);
        vm.expectRevert(AlreadyInitialized.selector);
        franchiser.initialize(Utils.bob, 0);
        vm.expectRevert(AlreadyInitialized.selector);
        franchiser.initialize(Utils.alice, Utils.bob, 0);
    }

    function testSubDelegateRevertsNotDelegatee() public {
        franchiser.initialize(Utils.alice, Utils.bob, 0);
        vm.expectRevert(abi.encodeWithSelector(NotDelegatee.selector, Utils.alice, Utils.bob));
        vm.prank(Utils.alice);
        franchiser.subDelegate(address(1), 0);
    }

    function testSubDelegateRevertsCannotExceedMaximumSubDelegatees() public {
        franchiser.initialize(Utils.alice, Utils.bob, 0);
        vm.expectRevert(abi.encodeWithSelector(CannotExceedMaximumSubDelegatees.selector, 0));
        vm.prank(Utils.bob);
        franchiser.subDelegate(address(1), 0);
    }

    function testSubDelegateZero() public {
        franchiser.initialize(Utils.alice, Utils.bob, 1);
        Franchiser expectedFranchiser = franchiser.getFranchiser(Utils.carol);

        vm.expectEmit(true, true, false, true, address(expectedFranchiser));
        emit Initialized(address(franchiser), Utils.bob, Utils.carol, 0);
        vm.expectEmit(true, false, false, true, address(franchiser));
        emit SubDelegateeActivated(Utils.carol);

        vm.prank(Utils.bob);
        Franchiser returnedFranchiser = franchiser.subDelegate(Utils.carol, 0);

        assertEq(address(expectedFranchiser), address(returnedFranchiser));

        address[] memory expectedSubDelegatees = new address[](1);
        expectedSubDelegatees[0] = Utils.carol;
        assertEq(franchiser.subDelegatees(), expectedSubDelegatees);

        assertEq(returnedFranchiser.owner(), address(franchiser));
        assertEq(returnedFranchiser.delegator(), Utils.bob);
        assertEq(returnedFranchiser.delegatee(), Utils.carol);
        assertEq(returnedFranchiser.maximumSubDelegatees(), 0);
        assertEq(returnedFranchiser.subDelegatees(), new address[](0));
        assertEq(votingToken.delegates(address(returnedFranchiser)), Utils.carol);
    }

    function testSubDelegateZeroNested() public {
        franchiser.initialize(Utils.alice, Utils.bob, 2);

        vm.prank(Utils.bob);
        Franchiser carolFranchiser = franchiser.subDelegate(Utils.carol, 0);
        vm.prank(Utils.carol);
        Franchiser daveFranchiser = carolFranchiser.subDelegate(Utils.dave, 0);

        assertEq(carolFranchiser.maximumSubDelegatees(), 1);
        assertEq(daveFranchiser.maximumSubDelegatees(), 0);
    }

    function testSubDelegateCanCallTwice() public {
        franchiser.initialize(Utils.alice, Utils.bob, 2);
        vm.startPrank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 0);
        franchiser.subDelegate(Utils.carol, 0);
        vm.stopPrank();
    }

    function testSubDelegateNonZeroFull() public {
        franchiser.initialize(Utils.alice, Utils.bob, 1);
        votingToken.mint(address(franchiser), 100);
        vm.prank(Utils.bob);
        Franchiser returnedFranchiser = franchiser.subDelegate(Utils.carol, 100);

        assertEq(votingToken.balanceOf(address(returnedFranchiser)), 100);
    }

    function testSubDelegateNonZeroPartial() public {
        franchiser.initialize(Utils.alice, Utils.bob, 1);
        votingToken.mint(address(franchiser), 100);
        vm.prank(Utils.bob);
        Franchiser returnedFranchiser = franchiser.subDelegate(Utils.carol, 50);

        assertEq(votingToken.balanceOf(address(franchiser)), 50);
        assertEq(votingToken.balanceOf(address(returnedFranchiser)), 50);
    }

    function testFuzz_SubDelegateBalancesUpdated(
        address _delegator,
        address _delegatee,
        address _subDelegatee,
        uint256 _amount
    ) public {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_delegatee != address(0));
        vm.assume(_subDelegatee != address(0));
        vm.assume(_delegatee != _subDelegatee);
        _amount = _boundAmount(_amount);
        franchiser.initialize(_delegator, _delegatee, 1);
        votingToken.mint(address(franchiser), _amount);

        Franchiser _expectedSubFranchiser = franchiser.getFranchiser(_subDelegatee);
        uint256 _subFranchiserBalanceBefore = votingToken.balanceOf(address(_expectedSubFranchiser));
        uint256 _franchiserBalanceBefore = votingToken.balanceOf(address(franchiser));
        uint256 _delegateeVotingPowerBefore = votingToken.getVotes(_delegatee);
        uint256 _subDelegateeVotingPowerBefore = votingToken.getVotes(_subDelegatee);
        vm.prank(_delegatee);
        Franchiser subFranchiser = franchiser.subDelegate(_subDelegatee, _amount);

        assertEq(votingToken.balanceOf(address(subFranchiser)), _subFranchiserBalanceBefore + _amount);
        assertEq(votingToken.balanceOf(address(franchiser)), _franchiserBalanceBefore - _amount);
        assertEq(votingToken.getVotes(_delegatee), _delegateeVotingPowerBefore - _amount);
        assertEq(votingToken.getVotes(_subDelegatee), _subDelegateeVotingPowerBefore + _amount);
    }

    function testFuzz_RevertIf_SubDelegateCalledWithFranchiserBalanceTooLow(
        address _delegator,
        address _delegatee,
        address _subDelegatee,
        uint256 _amount,
        uint256 _delta
    ) public {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_delegatee != address(0));
        vm.assume(_subDelegatee != address(0));
        _delta = bound(_delta, 1, 100_000_000e18);
        _amount = bound(_amount, _delta, 100_000_000e18);
        franchiser.initialize(_delegator, _delegatee, 1);
        votingToken.mint(address(franchiser), _amount - _delta);

        vm.expectRevert(bytes("TRANSFER_FAILED"));
        vm.prank(_delegatee);
        franchiser.subDelegate(_subDelegatee, _amount);
    }

    function testSubDelegateManyRevertsArrayLengthMismatch() public {
        franchiser.initialize(Utils.alice, Utils.bob, 2);

        address[] memory subDelegatees = new address[](0);
        uint256[] memory amounts = new uint256[](1);

        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 0, 1));
        vm.prank(Utils.bob);
        franchiser.subDelegateMany(subDelegatees, amounts);
    }

    function testSubDelegateMany() public {
        franchiser.initialize(Utils.alice, Utils.bob, 2);

        address[] memory subDelegatees = new address[](2);
        subDelegatees[0] = Utils.carol;
        subDelegatees[1] = Utils.dave;

        uint256[] memory amounts = new uint256[](2);

        vm.prank(Utils.bob);
        Franchiser[] memory franchisers = franchiser.subDelegateMany(subDelegatees, amounts);
        assertEq(franchisers.length, 2);
    }

    function testUnSubDelegateRevertsNotDelegatee() public {
        franchiser.initialize(Utils.alice, Utils.bob, 1);
        vm.prank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 0);
        vm.expectRevert(abi.encodeWithSelector(NotDelegatee.selector, Utils.alice, Utils.bob));
        vm.prank(Utils.alice);
        franchiser.unSubDelegate(Utils.carol);
    }

    function testFuzz_RevertIf_DelegateeIsNotCaller(address _delegator, address _delegatee, address _caller) public {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_validActorAddress(_delegatee));
        vm.assume(_caller != _delegatee);
        franchiser.initialize(_delegator, _delegatee, 1);
        vm.prank(_delegatee);
        franchiser.subDelegate(Utils.carol, 0);
        vm.expectRevert(abi.encodeWithSelector(NotDelegatee.selector, _caller, _delegatee));
        vm.prank(_caller);
        franchiser.unSubDelegate(Utils.carol);
    }

    function testUnSubDelegateZero() public {
        franchiser.initialize(Utils.alice, Utils.bob, 1);

        vm.startPrank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 0);
        vm.expectEmit(true, false, false, true, address(franchiser));
        emit SubDelegateeDeactivated(Utils.carol);
        franchiser.unSubDelegate(Utils.carol);
        vm.stopPrank();

        assertEq(franchiser.subDelegatees(), new address[](0));
    }

    function testUnSubDelegateCanCallTwice() public {
        franchiser.initialize(Utils.alice, Utils.bob, 1);

        vm.startPrank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 0);
        franchiser.unSubDelegate(Utils.carol);
        franchiser.unSubDelegate(Utils.carol);
        vm.stopPrank();

        assertEq(franchiser.subDelegatees(), new address[](0));
    }

    function testUnSubDelegateNonZero() public {
        franchiser.initialize(Utils.alice, Utils.bob, 1);
        votingToken.mint(address(franchiser), 100);

        vm.startPrank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 100);
        franchiser.unSubDelegate(Utils.carol);
        vm.stopPrank();

        assertEq(franchiser.subDelegatees(), new address[](0));
        assertEq(votingToken.balanceOf(address(franchiser)), 100);
    }

    function testFuzz_UnSubDelegateBalanceUpdated(
        address _delegator,
        address _delegatee,
        address _subDelegatee,
        uint256 _amount
    ) public {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_delegatee != address(0));
        vm.assume(_subDelegatee != address(0));
        _amount = _boundAmount(_amount);
        franchiser.initialize(_delegator, _delegatee, 1);
        votingToken.mint(address(franchiser), _amount);

        vm.startPrank(_delegatee);
        Franchiser subFranchiser = franchiser.subDelegate(_subDelegatee, _amount);
        uint256 _subFranchiserBalanceBefore = votingToken.balanceOf(address(subFranchiser));
        uint256 _franchiserBalanceBefore = votingToken.balanceOf(address(franchiser));
        franchiser.unSubDelegate(_subDelegatee);
        vm.stopPrank();

        assertEq(votingToken.balanceOf(address(franchiser)), _franchiserBalanceBefore + _amount);
        assertEq(votingToken.balanceOf(address(subFranchiser)), _subFranchiserBalanceBefore - _amount);
    }

    function testUnSubDelegateMany() public {
        franchiser.initialize(Utils.alice, Utils.bob, 2);

        address[] memory subDelegatees = new address[](2);
        subDelegatees[0] = Utils.carol;
        subDelegatees[1] = Utils.dave;

        vm.startPrank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 0);
        franchiser.subDelegate(Utils.dave, 0);
        franchiser.unSubDelegateMany(subDelegatees);
        vm.stopPrank();
    }

    function testUnSubDelegateManyRevertsNotDelegatee() public {
        franchiser.initialize(Utils.alice, Utils.bob, 2);

        address[] memory subDelegatees = new address[](2);
        subDelegatees[0] = Utils.carol;
        subDelegatees[1] = Utils.dave;

        vm.startPrank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 0);
        franchiser.subDelegate(Utils.dave, 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(NotDelegatee.selector, Utils.alice, Utils.bob));
        vm.prank(Utils.alice);
        franchiser.unSubDelegateMany(subDelegatees);
    }

    // max subdelegate
    function testFuzz_RevertIf_SubDelegateIsBeyondMax(
        address _delegator,
        address _delegatee,
        address _subDelegatee2,
        address _subDelegatee1
    ) public {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_validActorAddress(_delegatee));
        vm.assume(_validActorAddress(_subDelegatee1));
        vm.assume(_validActorAddress(_subDelegatee2));
        vm.assume(_subDelegatee1 != _subDelegatee2);

        vm.prank(_delegator);
        franchiser.initialize(_delegator, _delegatee, 1);

        vm.startPrank(_delegatee);
        franchiser.subDelegate(_subDelegatee1, 0);
        vm.expectRevert(abi.encodeWithSelector(CannotExceedMaximumSubDelegatees.selector, 1));
        franchiser.subDelegate(_subDelegatee2, 0);
        vm.stopPrank();
    }

    function testRecallRevertsUNAUTHORIZED() public {
        vm.expectRevert(bytes("UNAUTHORIZED"));
        vm.prank(address(1));
        franchiser.recall(address(0));
    }

    function testFuzz_RevertIf_NotCalledByDelegator(
        address _delegatee,
        address _attacker,
        address _delegator,
        uint256 _amount
    ) public {
        vm.assume(_validActorAddress(_delegatee));
        vm.assume(_validActorAddress(_attacker));
        vm.assume(_validActorAddress(_delegator));
        _amount = bound(_amount, 4, 100_000_000e18);
        votingToken.mint(_delegator, _amount);

        vm.prank(_delegator);
        franchiser = Franchiser(address(franchiserImplementation).clone());

        vm.prank(_delegator);
        franchiser.initialize(_delegator, _delegatee, 2);

        vm.prank(_attacker);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        franchiser.recall(_attacker);
    }

    function testRecallZeroNoSubDelegatees() public {
        vm.startPrank(Utils.alice);
        franchiser.initialize(Utils.alice, Utils.bob, 0);
        franchiser.recall(Utils.alice);
        vm.stopPrank();
    }

    function testRecallNonZeroNoSubDelegatees() public {
        votingToken.mint(address(franchiser), 100);
        vm.startPrank(Utils.alice);
        franchiser.initialize(Utils.alice, Utils.bob, 0);
        franchiser.recall(Utils.alice);
        vm.stopPrank();
        assertEq(votingToken.balanceOf(address(Utils.alice)), 100);
    }

    function testRecallNonZeroOneSubDelegatee() public {
        votingToken.mint(address(franchiser), 100);
        vm.prank(Utils.alice);
        franchiser.initialize(Utils.alice, Utils.bob, 1);
        vm.prank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 50);
        vm.prank(Utils.alice);
        franchiser.recall(Utils.alice);
        assertEq(votingToken.balanceOf(address(Utils.alice)), 100);
    }

    function testRecallNonZeroTwoSubDelegatees() public {
        votingToken.mint(address(franchiser), 100);
        vm.prank(Utils.alice);
        franchiser.initialize(Utils.alice, Utils.bob, 2);
        vm.startPrank(Utils.bob);
        franchiser.subDelegate(Utils.carol, 25);
        franchiser.subDelegate(Utils.dave, 25);
        vm.stopPrank();
        vm.prank(Utils.alice);
        franchiser.recall(Utils.alice);
        assertEq(votingToken.balanceOf(address(Utils.alice)), 100);
    }

    function testRecallNonZeroNestedSubDelegatees() public {
        votingToken.mint(address(franchiser), 100);

        vm.prank(Utils.alice);
        franchiser.initialize(Utils.alice, Utils.bob, 2);

        vm.prank(Utils.bob);
        Franchiser carolFranchiser = franchiser.subDelegate(Utils.carol, 25);
        vm.prank(Utils.carol);
        carolFranchiser.subDelegate(Utils.dave, 25);

        vm.prank(Utils.alice);
        franchiser.recall(Utils.alice);
        assertEq(votingToken.balanceOf(address(Utils.alice)), 100);
    }

    function testFuzz_RecallNestedSubDelegateesBalancesUpdated(
        address _delegator,
        address _delegatee,
        address _subDelegatee1,
        address _subDelegatee2,
        uint256 _amount
    ) public {
        vm.assume(_validActorAddress(_delegator));
        vm.assume(_validActorAddress(_delegatee));
        vm.assume(_validActorAddress(_subDelegatee1));
        vm.assume(_subDelegatee2 != address(0));
        _amount = bound(_amount, 4, 100_000_000e18);

        votingToken.mint(address(franchiser), _amount);

        vm.prank(_delegator);
        franchiser.initialize(_delegator, _delegatee, 2);

        // sub-delegate one-fourth of the amount to each sub-delegatee
        vm.prank(_delegatee);
        Franchiser _subFranchiser1 = franchiser.subDelegate(_subDelegatee1, _amount / 4);
        vm.prank(_subDelegatee1);
        _subFranchiser1.subDelegate(_subDelegatee2, _amount / 4);

        vm.prank(_delegator);
        franchiser.recall(_delegator);
        assertEq(votingToken.balanceOf(_delegator), _amount);
    }
}
