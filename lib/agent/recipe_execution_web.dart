import 'dart:async';
import '../domain/query_contracts.dart';

Future<R> executeRecipe<P, R>(
  FutureOr<R> Function(P) operation,
  P payload, {
  bool Function()? cancelled,
}) async {
  if (cancelled?.call() == true) {
    throw const ErrorEnvelope(ErrorCode.cancelled, '查询已停止');
  }
  return operation(payload);
}
