import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/app_controller.dart';
import '../services/app_logs.dart';
import '../services/file_export.dart';
import 'widgets.dart';

class LogsPage extends StatefulWidget {
  final AppController controller;
  final FileExport? fileExport;
  const LogsPage({super.key, required this.controller, this.fileExport});
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
    final origin = shareOrigin(context);
    try {
      final file = await widget.controller.logs.exportDocument();
      await (widget.fileExport ?? FileExport()).deliver(
        file,
        suggestedName: 'ykt-helper-logs.txt',
        mimeType: 'text/plain',
        extension: 'txt',
        sharePositionOrigin: origin,
      );
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

  Future<void> _showDetail(AppLogEntry entry) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('日志详情'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: SelectableText(
            entry.detailText,
            key: const ValueKey('log-detail'),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await Clipboard.setData(ClipboardData(text: entry.detailText));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(
                dialogContext,
              ).showSnackBar(const SnackBar(content: Text('已复制')));
            } catch (_) {
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(
                dialogContext,
              ).showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
            }
          },
          child: const Text('复制'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

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
                          key: ValueKey('log-entry-$index'),
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
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _showDetail(entry),
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
