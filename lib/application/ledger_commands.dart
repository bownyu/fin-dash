import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/command_context.dart';
import '../domain/ledger_operations.dart';

/// Typed entry point for a reviewed form; operation ID is retained on retry.
class LedgerCommands {
  final WalletStore store;
  LedgerCommands(this.store);
  Future<Json> saveTransaction(
    LedgerTx transaction, {
    required String operationId,
    required String ledgerEpoch,
    LedgerTx? expected,
    String source = 'manual',
  }) => store.execute(
    CommandContext(
      operationId: operationId,
      ledgerEpoch: ledgerEpoch,
      source: source,
      payload: transaction.toJson(),
      expectedRecords: {
        transaction.id: expected == null ? null : digest(expected.toJson()),
      },
    ),
    (d) {
      LedgerOperations.putTransaction(
        d,
        transaction,
        mode: expected == null
            ? TransactionWrite.insert
            : TransactionWrite.upsert,
      );
      if (transaction.accountId != null) {
        d.settings['quickEntryAccountId'] = transaction.accountId;
      }
    },
  );
}
