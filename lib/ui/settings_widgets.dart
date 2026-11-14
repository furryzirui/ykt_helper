import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'widgets.dart';

/// Keeps related settings the same width on phones, tablets and desktop.
class SettingsList extends StatelessWidget {
  final List<Widget> children;
  const SettingsList({super.key, required this.children});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView(
      padding: EdgeInsets.symmetric(
        horizontal: math.max(16, (constraints.maxWidth - 760) / 2),
        vertical: 16,
      ),
      children: children,
    ),
  );
}

class SettingDescription extends StatelessWidget {
  final String text;
  const SettingDescription(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
    text,
    softWrap: true,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      height: 1.4,
    ),
  );
}

class SettingTile extends StatelessWidget {
  final IconData icon;
  final String title, description;
  final Widget? trailing;
  final VoidCallback? onTap;
  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    minVerticalPadding: 12,
    minLeadingWidth: 44,
    horizontalTitleGap: 16,
    leading: TintedIcon(icon),
    title: Text(title),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SettingDescription(description),
    ),
    trailing: trailing,
    onTap: onTap,
  );
}
