import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../app_version.dart';
import '../services/ota_service.dart';
import 'design.dart';

class OtaPage extends StatefulWidget {
  final OtaService? service;
  const OtaPage({super.key, this.service});
  @override
  State<OtaPage> createState() => _OtaPageState();
}

class _OtaPageState extends State<OtaPage> with WidgetsBindingObserver {
  late final service = widget.service ?? OtaService();
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if ((supported || widget.service != null) &&
        service.state == OtaState.idle) {
      service.check();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.service == null) service.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        service.state == OtaState.permission) {
      // Return from system settings without launching installation automatically.
      setState(() {});
    }
  }

  String size(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('应用更新')),
    body: AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final release = service.release, state = service.state;
        return PageList(
          children: [
            Text(
              'FinDash $appVersion',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              '从官方 GitHub Release 检查并下载更新。',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 20),
            if (!supported && widget.service == null)
              const Panel(child: Text('应用内升级仅支持 Android。'))
            else ...[
              Text(switch (state) {
                OtaState.checking => '正在检查更新…',
                OtaState.upToDate => '已是最新版本',
                OtaState.available => '发现新版本 ${release?.version}',
                OtaState.downloading => '正在下载安装包…',
                OtaState.ready => '安装包已校验，可交给系统安装',
                OtaState.permission => '需要允许 FinDash 安装更新',
                OtaState.installing => '正在验证并打开系统安装器…',
                OtaState.error => '更新未完成',
                _ => '检查新版本',
              }, style: Theme.of(context).textTheme.titleMedium),
              if (release != null && release.newer) ...[
                const SizedBox(height: 12),
                Text('版本 ${release.version} · ${size(release.sizeBytes)}'),
                if (release.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(release.notes),
                  ),
              ],
              if (state == OtaState.downloading && release != null) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: service.received / release.sizeBytes,
                ),
                const SizedBox(height: 8),
                Text('${size(service.received)} / ${size(release.sizeBytes)}'),
                TextButton(
                  onPressed: service.cancel,
                  child: const Text('取消下载'),
                ),
              ],
              if (service.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    service.error!,
                    style: const TextStyle(color: coral),
                  ),
                ),
              if (state == OtaState.permission) ...[
                const SizedBox(height: 12),
                const Text('系统会询问是否允许 FinDash 安装应用。允许后返回此页，再点击安装更新。'),
                TextButton(
                  onPressed: () => perform(context, service.openPermission),
                  child: const Text('打开系统安装权限设置'),
                ),
              ],
              const SizedBox(height: 16),
              if (!service.busy && service.downloadedPath != null)
                FilledButton(
                  onPressed: service.install,
                  child: const Text('安装更新'),
                )
              else if (!service.busy && release?.newer == true)
                FilledButton(
                  onPressed: service.download,
                  child: Text(
                    state == OtaState.error
                        ? '重新下载'
                        : '下载更新 · ${size(release!.sizeBytes)}',
                  ),
                ),
              if (!service.busy)
                TextButton(onPressed: service.check, child: const Text('重新检查')),
              const SizedBox(height: 16),
              const Text(
                '升级保留现有账本；安装仍需你在系统界面确认。',
                style: TextStyle(color: muted),
              ),
            ],
          ],
        );
      },
    ),
  );
}
