/// Why a request's `authPubkey` could not be turned into an identity.
enum SyncAuthFailure {
  /// `SyncEngine.signerFor` has nothing under that pubkey, by default no
  /// account in `ndk.accounts`.
  unknownAccount,

  /// The signer is there but cannot sign, so it cannot answer a NIP-42
  /// challenge. A pubkey only account is read only.
  cannotSign,

  /// The signer found under that pubkey signs as another one.
  signerMismatch,
}

/// A request names a pubkey ndk cannot authenticate as, so its pass did not
/// run. Reading anonymously instead would file the answers under an identity
/// that never signed for them, which nothing afterwards could tell apart.
class SyncAuthUnavailable implements Exception {
  const SyncAuthUnavailable({required this.pubkey, required this.reason});

  final String pubkey;
  final SyncAuthFailure reason;

  @override
  String toString() => switch (reason) {
    SyncAuthFailure.unknownAccount =>
      'SyncAuthUnavailable: no account for $pubkey',
    SyncAuthFailure.cannotSign =>
      'SyncAuthUnavailable: the account for $pubkey cannot sign',
    SyncAuthFailure.signerMismatch =>
      'SyncAuthUnavailable: the signer for $pubkey signs as another pubkey',
  };
}
