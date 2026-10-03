import 'command_context.dart';
import 'models.dart';

/// Host-only approval value. It has no fromJson/model-tool constructor.
class AuthorizationGrant {
  final String taskId,
      planId,
      planDigest,
      ledgerEpoch,
      operationId,
      userEventId;
  final Set<String> selectedItemIds;
  final int planRevision;
  static const policyVersion = 1;
  AuthorizationGrant({
    required this.taskId,
    required this.planId,
    required this.planDigest,
    required this.planRevision,
    required this.ledgerEpoch,
    required Set<String> selectedItemIds,
    required this.userEventId,
  }) : selectedItemIds = Set.unmodifiable(selectedItemIds),
       operationId = digest({
         'planId': planId,
         'planDigest': planDigest,
         'selected': selectedItemIds.toList()..sort(),
         'ledgerEpoch': ledgerEpoch,
         'policy': policyVersion,
       });
  Json toReceiptFields() => {
    'operationId': operationId,
    'taskId': taskId,
    'planId': planId,
    'planRevision': planRevision,
    'planDigest': planDigest,
    'ledgerEpoch': ledgerEpoch,
    'selectedItemIds': selectedItemIds.toList(),
    'trustedUserEventId': userEventId,
    'policyVersion': policyVersion,
  };
}

class ReviewPlan {
  final String id, taskId, ledgerEpoch, digest;
  final int revision;
  final List<Json> items;
  ReviewPlan({
    required this.id,
    required this.taskId,
    required this.ledgerEpoch,
    required this.digest,
    required this.revision,
    required List<Json> items,
  }) : items = List.unmodifiable(items);
}

enum UiBlockKind {
  text,
  metric,
  table,
  chart,
  question,
  changePreview,
  receipt,
}
