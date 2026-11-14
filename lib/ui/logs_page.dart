import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';

class LogsPage extends StatefulWidget {
  final AppController controller;
  const LogsPage({super.key, required this.controller});
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  bool _exporting = false;
  @override
  void initState() {
    super.initState();
    widget.controller.logs.initialize();
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final file = await widget.controller.logs.exportDocument();
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('日志导出失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller.logs,
    builder: (context, _) {
      final logs = widget.controller.logs;
      final entries = logs.entries;
      return Scaffold(
        appBar: AppBar(
          title: const Text('应用日志'),
          actions: [
            IconButton(
              tooltip: '导出日志文档',
              onPressed: _exporting ? null : _export,
              icon: const Icon(Icons.ios_share_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            if (logs.storageUnavailable)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('日志存储不可用，当前仅显示本次运行记录'),
              ),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('暂无日志'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 16),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            entry.success == false
                                ? Icons.error_outline_rounded
                                : Icons.history_rounded,
                            color: entry.success == false
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                          title: Text(entry.message),
                          subtitle: Text(
                            entry.time.toLocal().toString().split('.').first,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}
