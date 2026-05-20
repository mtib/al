import Foundation
import CryptoKit

/// X25519-sealed-box style encryption for one-shot log entries.
///
/// Wire format (returned by `seal`):
///   [ 32 bytes  X25519 ephemeral public key ]
///   [ 12 bytes  ChaCha20 nonce              ]
///   [  N bytes  ciphertext                  ]
///   [ 16 bytes  Poly1305 tag                ]
///
/// Symmetric key:
///   HKDF-SHA256(
///     ikm  = X25519(ephemeral_priv, server_pub),
///     salt = ephemeral_pub || server_pub,
///     info = "al-sealed-box-v1",
///     L    = 32,
///   )
///
/// The ephemeral private key is generated inside `seal` and dropped on return —
/// callers cannot decrypt their own output. The construction mirrors the
/// design in `docs/log-shipping-design.md`; we use ChaCha20-Poly1305 instead of
/// libsodium's XSalsa20-Poly1305 because CryptoKit ships the former natively.
enum Crypto {

    /// HKDF info string. Must match the server's `HKDF_INFO`.
    static let hkdfInfo = Data("al-sealed-box-v1".utf8)

    enum Error: Swift.Error {
        case invalidServerPublicKey
    }

    /// Seals `plaintext` for the holder of `serverPublicKey`.
    /// `serverPublicKey` is the raw 32-byte X25519 public key.
    static func seal(_ plaintext: Data, to serverPublicKey: Data) throws -> Data {
        guard serverPublicKey.count == 32 else { throw Error.invalidServerPublicKey }
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKey)

        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPubData = ephemeralPriv.publicKey.rawRepresentation

        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: serverKey)
        var salt = Data(capacity: 64)
        salt.append(ephemeralPubData)
        salt.append(serverPublicKey)

        let symmetricKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )

        let sealed = try ChaChaPoly.seal(plaintext, using: symmetricKey)
        // sealed.combined = nonce(12) || ciphertext || tag(16)
        var out = Data(capacity: ephemeralPubData.count + sealed.combined.count)
        out.append(ephemeralPubData)
        out.append(sealed.combined)
        return out
    }
}
