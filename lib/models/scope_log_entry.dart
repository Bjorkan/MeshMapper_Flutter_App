/// What one scope request came to, as the log tab shows it.
///
/// Only requests a repeater answered or refused are logged. A local failure,
/// an abort, a cancel or the distance gate never reached a repeater and stay
/// debug log lines.
enum ScopeLogOutcome {
  /// The repeater answered with its scope list (possibly empty).
  answered,

  /// The request went out and no answer came back in time.
  noResponse,

  /// The radio flooded the request instead of sending it direct.
  flooded,

  /// The repeater answered with something that is not a scope list.
  malformed,

  /// The radio refused a step with an error code.
  radioError,

  /// The repeater answered, but this device's hourly upload cap was full.
  withheldHourlyCap,
}

extension ScopeLogOutcomeLabel on ScopeLogOutcome {
  /// The outcome in plain words, as the log card shows it.
  String get label => switch (this) {
        ScopeLogOutcome.answered => 'Answered',
        ScopeLogOutcome.noResponse => 'No response from repeater',
        ScopeLogOutcome.flooded => 'Sent as a flood by the radio',
        ScopeLogOutcome.malformed => 'Unreadable answer',
        ScopeLogOutcome.radioError => 'Radio error',
        ScopeLogOutcome.withheldHourlyCap =>
          'Not uploaded: hourly limit reached',
      };
}

/// One scope request in the log.
class ScopeLogEntry {
  /// When the outcome was known (the answer's arrival for an answer).
  final DateTime timestamp;

  /// The discovery point the repeater was found from.
  final double latitude;
  final double longitude;

  /// The short repeater id, as the discovery that found it printed it.
  final String repeaterId;

  /// The repeater's full public key, upper-case hex.
  final String pubkeyHex;

  final ScopeLogOutcome outcome;

  /// The scope names exactly as received, for [ScopeLogOutcome.answered] and
  /// [ScopeLogOutcome.withheldHourlyCap]; null otherwise.
  final List<String>? scopes;

  const ScopeLogEntry({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.repeaterId,
    required this.pubkeyHex,
    required this.outcome,
    this.scopes,
  });
}
