import 'package:flutter/material.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/voice_input.dart';
import 'package:fin_dash/ui/voice_entry_sheet.dart';

class TestVault implements KeyVault {
  String? key;
  TestVault([this.key]);
  @override
  Future<String?> read(String provider) async => key;
  @override
  Future<void> write(String provider, String value) async {
    key = value;
  }
}

Future<WalletStore> emptyStore([MemoryStorage? storage]) async {
  final store = WalletStore(storage ?? MemoryStorage());
  await store.initialize();
  return store;
}

Future<WalletStore> configuredAiStore() async {
  final store = await emptyStore();
  await store.change(
    (d) => d.providerConfigs['custom'] = {
      'baseURL': 'https://example.com/v1',
      'model': 'test-model',
      'protocol': chatProtocol,
    },
  );
  return store;
}

const bank = WalletAccount(
  id: 'bank',
  name: '银行卡',
  category: 'funds',
  subType: 'bank_card',
  openingBalance: 100000,
);
const cash = WalletAccount(
  id: 'cash',
  name: '现金',
  category: 'funds',
  subType: 'cash',
  openingBalance: 10000,
);
const credit = WalletAccount(
  id: 'credit',
  name: '信用卡',
  category: 'credit',
  subType: 'credit_card',
  openingBalance: -20000,
  creditLimit: 100000,
);
LedgerTx tx({
  String id = 'tx',
  int amount = 150,
  TxType type = TxType.expense,
  String? account = 'bank',
  String? from,
  String? to,
  DateTime? date,
}) => LedgerTx(
  id: id,
  title: '测试账单',
  amount: amount,
  date: date ?? DateTime(2026, 10, 1, 12),
  type: type,
  category: type == TxType.income
      ? '工资'
      : type == TxType.expense
      ? '餐饮'
      : '转账',
  accountId: account,
  fromId: from,
  toId: to,
);

/// Opens the voice sheet over a blank page after the first frame, the way the
/// home page and the task list open it. Pump until settled before using it.
class VoiceSheetHost extends StatefulWidget {
  final VoiceInput? voice;
  final bool autoStart;
  const VoiceSheetHost({super.key, this.voice, this.autoStart = false});
  @override
  State<VoiceSheetHost> createState() => _VoiceSheetHostState();
}

class _VoiceSheetHostState extends State<VoiceSheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => showVoiceEntry(
        context,
        voice: widget.voice,
        autoStart: widget.autoStart,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}
