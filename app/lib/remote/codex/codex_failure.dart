/// Codex reports subscription exhaustion separately from request throttling.
/// Older remote hosts forward the message even when they omit the native code.
enum CodexFailureKind { usageLimit, rateLimit, unavailable, disconnected, timedOut }

final _usageWording = RegExp(
  r"\b(?:you(?:['’]ve| have) hit your usage limit|you(?:['’]ve| have) reached your usage limit"
  r"|usage limit (?:has been )?(?:reached|exceeded)|insufficient[_ ]quota"
  r"|your workspace is out of credits|you hit your spend cap)\b",
  caseSensitive: false,
);

final _retryAt = RegExp(
  r'\btry again at ((?:[A-Z][a-z]{2} \d{1,2}(?:st|nd|rd|th), \d{4} )?'
  r'\d{1,2}:\d{2} (?:AM|PM))\b',
  caseSensitive: false,
);

String? codexUsageRetryTime(String? message) => message == null ? null : _retryAt.firstMatch(message)?.group(1);

CodexFailureKind? codexFailureKind(String? code, {String? message}) {
  final key = code?.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '').replaceFirst(RegExp('^codex'), '');
  return switch (key) {
    'usagelimitexceeded' || 'usagelimitreached' || 'insufficientquota' => CodexFailureKind.usageLimit,
    'ratelimitexceeded' => CodexFailureKind.rateLimit,
    'serveroverloaded' ||
    'internalservererror' ||
    'policycapacityunavailable' ||
    'unavailable' => CodexFailureKind.unavailable,
    'httpconnectionfailed' ||
    'responsestreamconnectionfailed' ||
    'responsestreamdisconnected' ||
    'connectionclosed' => CodexFailureKind.disconnected,
    'remoteturnsilence' || 'requesttimeout' => CodexFailureKind.timedOut,
    _ when message != null && _usageWording.hasMatch(message) => CodexFailureKind.usageLimit,
    _ => null,
  };
}
