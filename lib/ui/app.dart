import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app/app_controller.dart';
import '../domain/models.dart' as domain;
import '../services/startup_checks.dart';
import 'course_pages.dart';
import 'live_page.dart';
import 'scan_page.dart';
import 'settings_page.dart';

ThemeData rainTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff287b83),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xff83cbd1) : const Color(0xff287b83),
        onPrimary: dark ? const Color(0xff07363b) : Colors.white,
        primaryContainer: dark
            ? const Color(0xff16464c)
            : const Color(0xffe2f1f2),
        onPrimaryContainer: dark
            ? const Color(0xffb5e7ea)
            : const Color(0xff205b62),
        surface: dark ? const Color(0xff111c24) : const Color(0xfff5f8fa),
        surfaceContainerLowest: dark ? const Color(0xff14212a) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xff1b2a34)
            : const Color(0xffeff4f6),
        onSurface: dark ? const Color(0xffe4edf2) : const Color(0xff1f3442),
        onSurfaceVariant: dark
            ? const Color(0xffacbec8)
            : const Color(0xff647985),
        outline: dark ? const Color(0xff637780) : const Color(0xffaabcc5),
        outlineVariant: dark
            ? const Color(0xff30444e)
            : const Color(0xffdfe8ed),
      );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: base.textTheme.copyWith(
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 21,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(letterSpacing: 0),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(letterSpacing: 0),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 16,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      prefixIconColor: scheme.onSurfaceVariant,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      iconColor: scheme.onSurfaceVariant,
      subtitleTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      elevation: 0,
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return base.textTheme.labelMedium?.copyWith(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          size: 23,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        );
      }),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class RainApp extends StatelessWidget {
  final AppController controller;
  final bool startupChecks;
  const RainApp({
    super.key,
    required this.controller,
    this.startupChecks = true,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ykt_helper',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: rainTheme(Brightness.light),
    darkTheme: rainTheme(Brightness.dark),
    home: StartupChecks(
      enabled: startupChecks,
      child: _Home(controller: controller),
    ),
  );
}

class _Home extends StatefulWidget {
  final AppController controller;
  const _Home({required this.controller});
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  int _index = 0;
  bool _scanning = false;
  static const _labels = ['课程', '动态', '设置'];

  Future<void> _openLiveLesson(domain.Lesson lesson) async {
    final account = widget.controller.account;
    final classroom = await widget.controller.enter(lesson);
    if (!mounted || !identical(account, widget.controller.account)) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _index = 1);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            LivePage(controller: widget.controller, classroom: classroom),
      ),
    );
  }

  Future<void> _scan() async {
    if (_scanning || widget.controller.account == null) return;
    final account = widget.controller.account;
    setState(() => _scanning = true);
    try {
      final value = await showQrScanner(context);
      if (!mounted ||
          value == null ||
          !identical(account, widget.controller.account)) {
        return;
      }
      final classroom = await widget.controller.scanAndEnter(value);
      if (!mounted || !identical(account, widget.controller.account)) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              LivePage(controller: widget.controller, classroom: classroom),
        ),
      );
    } catch (error) {
      if (mounted && identical(account, widget.controller.account)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final content = Column(
          children: [
            if (widget.controller.error != null && _index < 2)
              MaterialBanner(
                content: Text(widget.controller.error!),
                actions: [
                  TextButton(
                    onPressed: widget.controller.busy
                        ? null
                        : () async {
                            try {
                              await widget.controller.refresh();
                            } catch (_) {}
                          },
                    child: const Text('重试'),
                  ),
                ],
              ),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: [
                  CoursesPage(
                    controller: widget.controller,
                    onOpenLive: _openLiveLesson,
                  ),
                  LiveListPage(controller: widget.controller),
                  SettingsPage(controller: widget.controller),
                ],
              ),
            ),
          ],
        );
        return Scaffold(
          appBar: AppBar(
            title: Text(_labels[_index]),
            actions: [
              if (_index < 2)
                IconButton(
                  tooltip: '扫码进入课堂',
                  onPressed: _scanning || widget.controller.account == null
                      ? null
                      : _scan,
                  icon: _scanning
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.qr_code_scanner_rounded),
                ),
              if (_index < 2)
                IconButton(
                  tooltip: '刷新',
                  onPressed: widget.controller.busy
                      ? null
                      : () async {
                          try {
                            await widget.controller.refresh();
                          } catch (_) {}
                        },
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
          body: SafeArea(
            child: wide
                ? Row(
                    children: [
                      SingleChildScrollView(
                        primary: false,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (constraints.maxHeight - 80).clamp(
                              0,
                              double.infinity,
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: NavigationRail(
                              selectedIndex: _index,
                              labelType: NavigationRailLabelType.all,
                              onDestinationSelected: (index) =>
                                  setState(() => _index = index),
                              destinations: const [
                                NavigationRailDestination(
                                  icon: Icon(Icons.menu_book_outlined),
                                  selectedIcon: Icon(Icons.menu_book_rounded),
                                  label: Text('课程'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.class_outlined),
                                  selectedIcon: Icon(Icons.class_rounded),
                                  label: Text('动态'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.settings_outlined),
                                  selectedIcon: Icon(Icons.settings_rounded),
                                  label: Text('设置'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: content),
                    ],
                  )
                : content,
          ),
          bottomNavigationBar: wide
              ? null
              : DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  child: NavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: (index) =>
                        setState(() => _index = index),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.menu_book_outlined),
                        selectedIcon: Icon(Icons.menu_book_rounded),
                        label: '课程',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.class_outlined),
                        selectedIcon: Icon(Icons.class_rounded),
                        label: '动态',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings_rounded),
                        label: '设置',
                      ),
                    ],
                  ),
                ),
        );
      },
    ),
  );
}
