/// A runtime failure inside the SDK, such as a storage read or write that
/// failed or persisted SDK state that could not be read.
///
/// Futures returned by `OursPrivacy` complete with this exception for those
/// failures. Calling a method before `init` (or after `close`) still throws a
/// [StateError], and an invalid argument still throws an [ArgumentError].
class OursPrivacyException implements Exception {
  /// Creates an exception with a [message] and the underlying [cause], if
  /// any.
  const OursPrivacyException(this.message, {this.cause});

  /// What failed.
  final String message;

  /// The underlying error (for example the storage backend's exception), or
  /// null.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'OursPrivacyException: $message'
      : 'OursPrivacyException: $message (cause: $cause)';
}
