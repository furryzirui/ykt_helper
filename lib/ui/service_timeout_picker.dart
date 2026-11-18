import 'package:flutter/material.dart';

Future<int?> selectServiceTimeout(
  BuildContext context, {
  required int selected,
  bool allowNever = true,
}) => showDialog<int>(
  context: context,
  builder: (context) => SimpleDialog(
    title: const Text('定时关闭'),
    children: [
      for (final entry in const {
        10: '10 分钟',
        120: '2 小时',
        1440: '24 小时',
        0: '永不',
      }.entries)
        if (allowNever || entry.key != 0)
          SimpleDialogOption(
            key: ValueKey('service-timeout-${entry.key}'),
            onPressed: () => Navigator.of(context).pop(entry.key),
            child: Row(
              children: [
                Expanded(child: Text(entry.value)),
                if (selected == entry.key)
                  Icon(
                    Icons.check_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
    ],
  ),
);
