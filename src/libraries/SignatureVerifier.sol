// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library SignatureVerifier {
    error InvalidSignatureLength();
    error InvalidSignatureS();
    error InvalidSigner();

    // Constant secp256k1 curve order n / 2 to prevent signature malleability
    bytes32 private constant MALLEABILITY_THRESHOLD =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice Recovers signer address from message hash and compact 65-byte signature
    function recoverSigner(bytes32 messageHash, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        // Prevent signature malleability: s must be in the lower half of secp256k1 curve order
        if (uint256(s) > uint256(MALLEABILITY_THRESHOLD)) {
            revert InvalidSignatureS();
        }

        if (v < 27) {
            v += 27;
        }

        address signer = ecrecover(messageHash, v, r, s);
        if (signer == address(0)) revert InvalidSigner();

        return signer;
    }

    /// @notice Formats message hash using Ethereum Signed Message prefix
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}
