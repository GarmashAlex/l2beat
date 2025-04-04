// SPDX-License-Identifier: Unknown
pragma solidity 0.6.12;

interface IFactRegistry {
    /*
      Returns true if the given fact was previously registered in the contract.
    */
    function isValid(bytes32 fact) external view returns (bool);
}

interface IQueryableFactRegistry is IFactRegistry {
    /*
      Returns true if at least one fact has been registered.
    */
    function hasRegisteredFact() external view returns (bool);
}

contract FactRegistry is IQueryableFactRegistry {
    // Mapping: fact hash -> true.
    mapping(bytes32 => bool) private verifiedFact;

    // Indicates whether the Fact Registry has at least one fact registered.
    bool anyFactRegistered;

    /*
      Checks if a fact has been verified.
    */
    function isValid(bytes32 fact) external view override returns (bool) {
        return _factCheck(fact);
    }

    /*
      This is an internal method to check if the fact is already registered.
      In current implementation of FactRegistry it's identical to isValid().
      But the check is against the local fact registry,
      So for a derived referral fact registry, it's not the same.
    */
    function _factCheck(bytes32 fact) internal view returns (bool) {
        return verifiedFact[fact];
    }

    function registerFact(bytes32 factHash) internal {
        // This function stores the fact hash in the mapping.
        verifiedFact[factHash] = true;

        // Mark first time off.
        if (!anyFactRegistered) {
            anyFactRegistered = true;
        }
    }

    /*
      Indicates whether at least one fact was registered.
    */
    function hasRegisteredFact() external view override returns (bool) {
        return anyFactRegistered;
    }
}

interface IAvailabilityVerifier {
    /*
      Verifies the availability proof. Reverts if invalid.
    */
    function verifyAvailabilityProof(bytes32 claimHash, bytes calldata availabilityProofs) external;
}

interface Identity {
    /*
      Allows a caller, typically another contract,
      to ensure that the provided address is of the expected type and version.
    */
    function identify() external pure returns (string memory);
}

contract Committee is FactRegistry, IAvailabilityVerifier, Identity {
    uint256 constant SIGNATURE_LENGTH = 32 * 2 + 1; // r(32) + s(32) +  v(1).
    uint256 public signaturesRequired;
    mapping(address => bool) public isMember;

    /// @dev Contract constructor sets initial members and required number of signatures.
    /// @param committeeMembers List of committee members.
    /// @param numSignaturesRequired Number of required signatures.
    constructor(address[] memory committeeMembers, uint256 numSignaturesRequired) public {
        require(numSignaturesRequired > 0, "NO_REQUIRED_SIGNATURES");
        require(numSignaturesRequired <= committeeMembers.length, "TOO_MANY_REQUIRED_SIGNATURES");
        for (uint256 idx = 0; idx < committeeMembers.length; idx++) {
            require(
                !isMember[committeeMembers[idx]] && (committeeMembers[idx] != address(0)),
                "NON_UNIQUE_COMMITTEE_MEMBERS"
            );
            isMember[committeeMembers[idx]] = true;
        }
        signaturesRequired = numSignaturesRequired;
    }

    function identify() external pure virtual override returns (string memory) {
        return "StarkWare_Committee_2022_2";
    }

    /// @dev Verifies the availability proof. Reverts if invalid.
    /// An availability proof should have a form of a concatenation of ec-signatures by signatories.
    /// Signatures should be sorted by signatory address ascendingly.
    /// Signatures should be 65 bytes long. r(32) + s(32) + v(1).
    /// There should be at least the number of required signatures as defined in this contract
    /// and all signatures provided should be from signatories.
    ///
    /// See :sol:mod:`AvailabilityVerifiers` for more information on when this is used.
    ///
    /// @param claimHash The hash of the claim the committee is signing on.
    /// The format is keccak256(abi.encodePacked(
    ///    newValidiumVaultRoot, validiumTreeHeight, newOrderRoot, orderTreeHeight sequenceNumber))
    /// @param availabilityProofs Concatenated ec signatures by committee members.
    function verifyAvailabilityProof(bytes32 claimHash, bytes calldata availabilityProofs)
        external
        override
    {
        require(
            availabilityProofs.length >= signaturesRequired * SIGNATURE_LENGTH,
            "INVALID_AVAILABILITY_PROOF_LENGTH"
        );

        uint256 offset = 0;
        address prevRecoveredAddress = address(0);
        for (uint256 proofIdx = 0; proofIdx < signaturesRequired; proofIdx++) {
            bytes32 r = bytesToBytes32(availabilityProofs, offset);
            bytes32 s = bytesToBytes32(availabilityProofs, offset + 32);
            uint8 v = uint8(availabilityProofs[offset + 64]);
            offset += SIGNATURE_LENGTH;
            address recovered = ecrecover(claimHash, v, r, s);
            // Signatures should be sorted off-chain before submitting to enable cheap uniqueness
            // check on-chain.
            require(isMember[recovered], "AVAILABILITY_PROVER_NOT_IN_COMMITTEE");
            require(recovered > prevRecoveredAddress, "NON_SORTED_SIGNATURES");
            prevRecoveredAddress = recovered;
        }
        registerFact(claimHash);
    }

    function bytesToBytes32(bytes memory array, uint256 offset)
        private
        pure
        returns (bytes32 result)
    {
        // Arrays are prefixed by a 256 bit length parameter.
        uint256 actualOffset = offset + 32;

        // Read the bytes32 from array memory.
        assembly {
            result := mload(add(array, actualOffset))
        }
    }
}

abstract contract SimpleAdminable {
    address owner;
    address ownerCandidate;
    mapping(address => bool) admins;

    constructor() internal {
        owner = msg.sender;
        admins[msg.sender] = true;
    }

    // Admin/Owner Modifiers.
    modifier onlyOwner() {
        require(isOwner(msg.sender), "ONLY_OWNER");
        _;
    }

    function isOwner(address testedAddress) public view returns (bool) {
        return owner == testedAddress;
    }

    modifier onlyAdmin() {
        require(isAdmin(msg.sender), "ONLY_ADMIN");
        _;
    }

    function isAdmin(address testedAddress) public view returns (bool) {
        return admins[testedAddress];
    }

    function registerAdmin(address newAdmin) external onlyOwner {
        if (!isAdmin(newAdmin)) {
            admins[newAdmin] = true;
        }
    }

    function removeAdmin(address removedAdmin) external onlyOwner {
        require(!isOwner(removedAdmin), "OWNER_CANNOT_BE_REMOVED_AS_ADMIN");
        delete admins[removedAdmin];
    }

    function nominateNewOwner(address newOwner) external onlyOwner {
        require(!isOwner(newOwner), "ALREADY_OWNER");
        ownerCandidate = newOwner;
    }

    function acceptOwnership() external {
        // Previous owner is still an admin.
        require(msg.sender == ownerCandidate, "NOT_A_CANDIDATE");
        owner = ownerCandidate;
        admins[ownerCandidate] = true;
        ownerCandidate = address(0x0);
    }
}

abstract contract Finalizable is SimpleAdminable {
    bool finalized;

    function isFinalized() public view returns (bool) {
        return finalized;
    }

    modifier notFinalized() {
        require(!isFinalized(), "FINALIZED");
        _;
    }

    function finalize() external onlyAdmin {
        finalized = true;
    }
}

contract FinalizableCommittee is Finalizable, Committee {
    event RequiredSignersIncrement(uint256 newRequiredSigners);
    event NewMemberAdded(address newMember);

    uint256 private _memberCount;

    constructor(address[] memory committeeMembers, uint256 numSignaturesRequired)
        public
        Committee(committeeMembers, numSignaturesRequired)
    {
        _memberCount = committeeMembers.length;
    }

    function incrementRequiredSigners() external notFinalized onlyAdmin {
        require(signaturesRequired < _memberCount, "TOO_MANY_REQUIRED_SIGNATURES");
        signaturesRequired += 1;
        emit RequiredSignersIncrement(signaturesRequired);
    }

    function addCommitteeMemeber(address newMember) external notFinalized onlyAdmin {
        require(newMember != address(0x0), "INVALID_MEMBER");
        require(!isMember[newMember], "ALREADY_MEMBER");
        isMember[newMember] = true;
        _memberCount += 1;
        emit NewMemberAdded(newMember);
    }

    function identify() external pure override returns (string memory) {
        return "StarkWare_FinalizableCommittee_2022_1";
    }
}