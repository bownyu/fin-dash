import 'models.dart';

enum ErrorCode {
  invalidInput,
  missingField,
  locked,
  forbidden,
  stalePlan,
  staleInteraction,
  versionConflict,
  limitExceeded,
  snapshotExpired,
  storageFailed,
  modelUnavailable,
  capabilityUnavailable,
  cancelled,
  interrupted,
}

class ErrorEnvelope implements Exception {
  final ErrorCode code;
  final String userMessage, phase;
  final bool retryable;
  final List<String> recoveryOptions;
  const ErrorEnvelope(
    this.code,
    this.userMessage, {
    this.phase = 'query',
    this.retryable = false,
    this.recoveryOptions = const [],
  });
  Json toJson() => {
    'ok': false,
    'code': code.name
        .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]}')
        .toUpperCase(),
    'userMessage': userMessage,
    'phase': phase,
    'retryable': retryable,
    'recoveryOptions': recoveryOptions,
  };
  @override
  String toString() => userMessage;
}

class QuerySnapshot {
  final String ledgerEpoch;
  final int revision;
  const QuerySnapshot(this.ledgerEpoch, this.revision);
  Json toJson() => {'ledgerEpoch': ledgerEpoch, 'revision': revision};
}

class QueryScope {
  final DateRange? range;
  final String timezone, currency, metric;
  const QueryScope({
    this.range,
    this.timezone = 'local',
    this.currency = 'CNY',
    this.metric = 'recordedTransactions',
  });
  Json toJson() => {
    'startInclusive': range?.start.toIso8601String(),
    'endExclusive': range?.end.toIso8601String(),
    'timezone': timezone,
    'currency': currency,
    'metric': metric,
  };
}

class QueryResult<T> {
  final T data;
  final QueryScope scope;
  final QuerySnapshot snapshot;
  final int matchedRows, returnedRows;
  final String status, evidenceRef;
  final String? nextCursor, partialReason;
  final List<String> limitations;
  final DateTime asOf;
  QueryResult({
    required this.data,
    required this.scope,
    required this.snapshot,
    required this.matchedRows,
    required this.returnedRows,
    this.status = 'complete',
    this.nextCursor,
    this.partialReason,
    this.limitations = const [],
    String? evidenceRef,
    DateTime? asOf,
  }) : evidenceRef = evidenceRef ?? newId(),
       asOf = asOf ?? DateTime.now();
  Json toJson() => {
    'ok': true,
    'data': data,
    'scope': scope.toJson(),
    'snapshot': snapshot.toJson(),
    'coverage': {
      'status': status,
      'matchedRows': matchedRows,
      'returnedRows': returnedRows,
      'sourceCoverage': 'recordedLedgerOnly',
      if (partialReason != null) 'reason': partialReason,
    },
    'asOf': asOf.toIso8601String(),
    'nextCursor': nextCursor,
    'evidenceRef': evidenceRef,
    'limitations': limitations,
  };
}

int checkedCents(int value) {
  if (value.abs() > 9007199254740991) {
    throw const ErrorEnvelope(ErrorCode.limitExceeded, '金额合计超出精确计算范围');
  }
  return value;
}
