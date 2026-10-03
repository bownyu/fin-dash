import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'design.dart';
import 'query_result_card.dart';

class SavedAnalysesPage extends StatefulWidget {
  const SavedAnalysesPage({super.key});
  @override
  State<SavedAnalysesPage> createState() => _SavedAnalysesPageState();
}

class _SavedAnalysesPageState extends State<SavedAnalysesPage> {
  String? running, error;
  Json? result;
  @override
  Widget build(BuildContext context) {
    final ai = AppScope.of(context).ai;
    final saved =
        AppScope.storeOf(context).data.extras['savedRecipes'] as List? ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('常用分析')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (saved.isEmpty) const Text('在查询结果中选择“保存为常用分析”，即可在这里重新运行。'),
          for (final value in saved)
            ListTile(
              title: Text('${value['title']}'),
              subtitle: const Text('使用当前账本重新计算'),
              trailing: TextButton(
                onPressed: running != null
                    ? null
                    : () async {
                        setState(() {
                          running = value['id'];
                          error = null;
                        });
                        try {
                          final next = await ai.capabilities.runSavedRecipe(
                            value['id'],
                          );
                          if (mounted) setState(() => result = next);
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        } finally {
                          if (mounted) setState(() => running = null);
                        }
                      },
                child: Text(running == value['id'] ? '计算中…' : '运行'),
              ),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (result != null) QueryResultCard(result: result!),
        ],
      ),
    );
  }
}
