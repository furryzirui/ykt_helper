import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import '../services/ai_answer.dart';
import '../services/app_logs.dart';
import 'settings_widgets.dart';
import 'widgets.dart';

class AutomationDraft {
  AppSettings? settings;
  AppSettings? source;
  void clear() {
    settings = null;
    source = null;
  }
}

class AutomationPage extends StatefulWidget {
  final AppController controller;
  final AutomationDraft? draft;
  const AutomationPage({super.key, required this.controller, this.draft});
  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage>
    with WidgetsBindingObserver {
  final _fields = <String, TextEditingController>{};
  bool _saving = false, _seenInitialized = false;
  AppSettings? _draft, _source;
  Timer? _modelDebounce, _saveDebounce;
  Future<void>? _saveFlight;
  bool _dirty = false, _saveAgain = false, _leaving = false, _canPop = false;
  bool _closing = false;
  int _editRevision = 0;
  final _controlRevisions = <String, int>{};
  String? _saveError;
  int _modelGeneration = 0;
  bool _loadingModels = false, _defaultModelSelected = false;
  List<String> _models = [];
  String? _modelsError, _loadedBaseUrl, _loadedApiKey;
  String? _autostartPermission;
  bool _checkingAutostartPermission = false;
  int _autostartPermissionGeneration = 0;
  Future<bool>? _latestPermissionCheck;
  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;
  bool get _windowsAutostartAllowed =>
      !_checkingAutostartPermission && _autostartPermission != 'denied';
  bool get _disabled => !widget.controller.initialized;
  bool get _modelsLoaded =>
      !_loadingModels &&
      _loadedBaseUrl == _draft?.baseUrl.trim() &&
      _loadedApiKey == _draft?.apiKey.trim() &&
      _models.isNotEmpty;
  bool get _modelsReady => _modelsLoaded && _models.contains(_draft?.model);

  @override
  void initState() {
    super.initState();
    final cached = widget.draft;
    if (cached?.settings != null &&
        identical(cached?.source, widget.controller.settings)) {
      _draft = _copy(cached!.settings!);
      _source = cached.source;
      _dirty = !_sameSettings(_draft!, _source!);
    }
    WidgetsBinding.instance.addObserver(this);
    if (_windows) unawaited(_refreshAutostartPermission());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_windows && state == AppLifecycleState.resumed) {
      unawaited(_refreshAutostartPermission());
    }
  }

  Future<bool> _refreshAutostartPermission() {
    final check = _readAutostartPermission();
    _latestPermissionCheck = check;
    return check;
  }

  Future<bool> _readAutostartPermission() async {
    if (!_windows) return true;
    if (_closing) {
      try {
        return await widget.controller.autostart.permissionStatus() != 'denied';
      } catch (_) {
        return true;
      }
    }
    final generation = ++_autostartPermissionGeneration;
    setState(() {
      _checkingAutostartPermission = true;
    });
    String? permission;
    try {
      permission = await widget.controller.autostart.permissionStatus();
    } catch (_) {}
    if (!mounted) return permission != 'denied';
    if (generation != _autostartPermissionGeneration) {
      return await _latestPermissionCheck ?? _autostartPermission != 'denied';
    }
    setState(() {
      _checkingAutostartPermission = false;
      _autostartPermission = permission;
    });
    return _windowsAutostartAllowed;
  }

  String get _windowsAutostartDescription {
    if (_checkingAutostartPermission) return '正在检查自启动权限';
    if (_autostartPermission == 'denied') return '系统已禁用自启动';
    return '登录 Windows 后在后台启动自动化';
  }

  Future<bool> _confirmAutostartPermission() async {
    if (await _refreshAutostartPermission()) return true;
    if (mounted) {
      _showError('系统已禁用自启动');
    }
    return false;
  }

  void _readSettings(AppSettings source) {
    _source = source;
    _draft = _copy(source);
    final values = {
      'fixedSingle': source.fixedSingleAnswer,
      'fixedMultiple': source.fixedMultipleAnswer,
      'fixedSubjective': source.fixedSubjectiveAnswer,
      'baseUrl': source.baseUrl,
      'apiKey': source.apiKey,
      'prompt': source.customPrompt,
      'slidePrompt': source.slidePrompt,
      'submitDelay': '${source.autoSubmitDelaySeconds}',
    };
    for (final entry in _fields.entries) {
      entry.value.text = values[entry.key] ?? '';
    }
    if (!_modelsReady) _scheduleModels();
  }

  static AppSettings _copy(AppSettings value) =>
      AppSettings.fromJson(value.toJson())
        ..customPrompt = value.customPrompt
        ..autoSubmitDelaySeconds = value.autoSubmitDelaySeconds;

  static bool _sameSettings(AppSettings first, AppSettings second) =>
      jsonEncode(first.toJson()) == jsonEncode(second.toJson());

  void _edit(VoidCallback change, {String? control, bool text = false}) {
    setState(change);
    _queueSave(control: control, text: text);
  }

  void _queueSave({String? control, bool text = false}) {
    _editRevision++;
    _dirty = true;
    if (control != null) _controlRevisions[control] = _editRevision;
    _saveDebounce?.cancel();
    setState(() => _saveError = null);
    if (text) {
      _saveDebounce = Timer(const Duration(milliseconds: 600), _flushSaves);
    } else {
      unawaited(_flushSaves());
    }
  }

  String? _validationError(AppSettings value) {
    // Inactive answer settings must not block sign-in or startup preferences.
    if (!value.autoAnswer) return null;
    if (value.autoSubmit &&
        (value.autoSubmitDelaySeconds < 1 ||
            value.autoSubmitDelaySeconds > 3600)) {
      return '提交延迟请输入 1–3600 秒';
    }
    if (value.answerMode == AnswerMode.fixed) {
      if (!RegExp(r'^[A-D]$').hasMatch(value.fixedSingleAnswer) ||
          !RegExp(r'^[A-D]+$').hasMatch(value.fixedMultipleAnswer) ||
          value.fixedMultipleAnswer.split('').toSet().length !=
              value.fixedMultipleAnswer.length ||
          !RegExp(r'^[AB]$').hasMatch(value.fixedJudgmentAnswer)) {
        return '请选择 A–D 范围内的单选和多选答案';
      }
      return value.hasCompleteFixedAnswers ? null : '请填写全部固定答案';
    }
    try {
      AiAnswerService.endpoint(value.baseUrl, 'chat/completions');
    } on ApiFailure catch (error) {
      return error.message;
    }
    if (value.apiKey.trim().isEmpty) return '请填写 api_key';
    if (value.customPrompt.trim().isEmpty) return '请填写 AI 提示词';
    if (!_modelsReady) return '请获取并选择当前 AI 服务的模型';
    return null;
  }

  AppSettings _safetyChanges(AppSettings requested) {
    final candidate = _copy(widget.controller.settings);
    for (final control in _controlRevisions.keys) {
      switch (control) {
        case 'autoEnter':
          candidate.autoEnter = requested.autoEnter;
        case 'autoAnswer':
          if (!requested.autoAnswer) candidate.autoAnswer = false;
        case 'autoSubmit':
          if (!requested.autoSubmit) candidate.autoSubmit = false;
        case 'autoStartService':
          if (!requested.autoStartService) candidate.autoStartService = false;
        case 'appAutoStart':
          if (!requested.appAutoStart) candidate.appAutoStart = false;
      }
    }
    return candidate;
  }

  void _cacheDraft() {
    widget.draft?.settings = _draft == null ? null : _copy(_draft!);
    widget.draft?.source = _source;
  }

  Future<void> _flushSaves() {
    _saveDebounce?.cancel();
    if (_saveFlight != null) {
      _saveAgain = true;
      return _saveFlight!;
    }
    final completion = Completer<void>();
    _saveFlight = completion.future;
    unawaited(
      _drainSaves().whenComplete(() {
        _saveFlight = null;
        completion.complete();
        if (_saveAgain && _dirty && _saveDebounce?.isActive != true) {
          unawaited(_flushSaves());
        }
      }),
    );
    return completion.future;
  }

  Future<void> _drainSaves() async {
    var attemptedRevision = -1;
    do {
      _saveAgain = false;
      if (!_dirty || _draft == null || !widget.controller.initialized) break;
      final revision = _editRevision;
      attemptedRevision = revision;
      final requested = _copy(_draft!);
      final validation = _validationError(requested);
      final candidate = validation == null
          ? requested
          : _safetyChanges(requested);
      if (mounted && !_closing) setState(() => _saveError = validation);
      if (_sameSettings(candidate, widget.controller.settings)) {
        if (_sameSettings(requested, widget.controller.settings)) {
          _dirty = false;
          _controlRevisions.clear();
          if (mounted && !_closing) setState(() => _saveError = null);
        }
        _source = widget.controller.settings;
        _cacheDraft();
        break;
      }
      if (_windows &&
          candidate.appAutoStart &&
          !widget.controller.settings.appAutoStart &&
          !await _refreshAutostartPermission()) {
        if (mounted && !_closing) setState(() => _saveError = '系统已禁用自启动');
        break;
      }
      if (revision != _editRevision) continue;
      if (mounted && !_closing) setState(() => _saving = true);
      try {
        await widget.controller.saveSettings(candidate);
        _source = widget.controller.settings;
        _controlRevisions.removeWhere((_, changedAt) => changedAt <= revision);
        if (revision == _editRevision && validation == null) {
          final committed = widget.controller.settings;
          _draft!
            ..autoEnter = committed.autoEnter
            ..autoAnswer = committed.autoAnswer
            ..autoSubmit = committed.autoSubmit
            ..autoStartService = committed.autoStartService
            ..appAutoStart = committed.appAutoStart;
          _dirty = !_sameSettings(_draft!, committed);
        }
        _cacheDraft();
      } catch (error) {
        if (mounted && !_closing && revision == _editRevision) {
          setState(
            () => _saveError = error is ApiFailure ? error.message : '保存失败，请重试',
          );
        }
      } finally {
        if (mounted && !_closing) setState(() => _saving = false);
      }
      if (_saveDebounce?.isActive == true) break;
    } while (_saveAgain || _dirty && _editRevision != attemptedRevision);
  }

  Future<void> _leave(bool didPop) async {
    if (didPop || _leaving) return;
    _leaving = true;
    await _flushSaves();
    if (!mounted) return;
    setState(() => _canPop = true);
    Navigator.of(context).pop();
  }

  void _scheduleModels({bool clearSelection = false, bool immediate = false}) {
    _modelDebounce?.cancel();
    final generation = ++_modelGeneration;
    _loadingModels = false;
    _modelsError = null;
    _defaultModelSelected = false;
    _models = [];
    _loadedBaseUrl = _loadedApiKey = null;
    final draft = _draft!;
    if (clearSelection) draft.model = '';
    if (!widget.controller.initialized ||
        !draft.autoAnswer ||
        draft.answerMode != AnswerMode.ai ||
        draft.baseUrl.trim().isEmpty ||
        draft.apiKey.trim().isEmpty) {
      return;
    }
    try {
      AiAnswerService.endpoint(draft.baseUrl, 'models');
    } on ApiFailure catch (failure) {
      _modelsError = failure.message;
      return;
    }
    final baseUrl = draft.baseUrl.trim(), apiKey = draft.apiKey.trim();
    _modelDebounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 500),
      () => _fetchModels(generation, baseUrl, apiKey),
    );
  }

  bool _currentModelRequest(int generation, String baseUrl, String apiKey) =>
      mounted &&
      generation == _modelGeneration &&
      _draft!.autoAnswer &&
      _draft!.answerMode == AnswerMode.ai &&
      _draft!.baseUrl.trim() == baseUrl &&
      _draft!.apiKey.trim() == apiKey;

  Future<void> _fetchModels(
    int generation,
    String baseUrl,
    String apiKey,
  ) async {
    if (!_currentModelRequest(generation, baseUrl, apiKey)) return;
    setState(() => _loadingModels = true);
    try {
      final models = await widget.controller.ai.models(
        baseUrl: baseUrl,
        apiKey: apiKey,
      );
      if (!_currentModelRequest(generation, baseUrl, apiKey)) return;
      if (models.isEmpty) throw const ApiFailure('AI 没有返回可选择的模型');
      setState(() {
        _models = models;
        _loadedBaseUrl = baseUrl;
        _loadedApiKey = apiKey;
        _loadingModels = false;
        if (_dirty && !models.contains(_draft!.model)) {
          _draft!.model = models.first;
          _defaultModelSelected = true;
        }
      });
      if (_dirty && _saveDebounce?.isActive != true) unawaited(_flushSaves());
    } catch (failure) {
      widget.controller.logs.add(
        AppLogEvent.automatic,
        success: false,
        code: failure is ApiFailure ? failure.code : null,
      );
      if (!_currentModelRequest(generation, baseUrl, apiKey)) return;
      setState(() {
        _loadingModels = false;
        _modelsError = failure is ApiFailure
            ? failure.message
            : '模型列表获取失败，请检查地址和密钥后重试';
      });
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  TextEditingController _field(String name, String value) =>
      _fields.putIfAbsent(name, () => TextEditingController(text: value));

  Widget _settingIcon(IconData icon) => TintedIcon(icon);

  Future<void> _setAppAutoStart(bool enabled) async {
    if (!enabled) {
      _edit(() => _draft!.appAutoStart = false, control: 'appAutoStart');
      return;
    }
    final windows = _windows;
    if (windows && !await _confirmAutostartPermission()) return;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('应用自启动'),
        content: Text(
          windows
              ? '用于登录 Windows 后在后台启动自动化。\n\n确认后添加启动项并自动保存，可在系统“启动应用”中管理。退出应用后，自动化将在下次登录 Windows 时恢复。'
              : '用于开机后以及系统允许的进程回收后恢复自动化。\n\n确认后自动保存，请在“应用权限 → 自启动”中允许自启动，并允许通知、取消电池优化。强行停止应用或系统禁止自启动后无法自动恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      if (windows) {
        try {
          await widget.controller.autostart.prepare();
        } catch (_) {
          if (mounted) _showError('无法添加自启动项，请重试');
          return;
        }
      }
      if (windows && !await _confirmAutostartPermission()) return;
      if (!mounted) return;
      _edit(() => _draft!.appAutoStart = true, control: 'appAutoStart');
    }
  }

  @override
  void dispose() {
    _closing = true;
    _saveDebounce?.cancel();
    if (_dirty) unawaited(_flushSaves());
    _autostartPermissionGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _cacheDraft();
    _modelDebounce?.cancel();
    _modelGeneration++;
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Widget _input(
    String name,
    String label,
    String value,
    ValueChanged<String> changed, {
    bool secret = false,
    int lines = 1,
    String? hint,
    String? helper,
    IconData? icon,
  }) => Padding(
    key: ValueKey('input-$name'),
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: ValueKey('field-$name'),
          enabled: !_disabled,
          controller: _field(name, value),
          obscureText: secret,
          minLines: lines,
          maxLines: lines,
          autocorrect: !secret,
          enableSuggestions: !secret,
          enableIMEPersonalizedLearning: !secret,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon: icon == null ? null : Icon(icon),
          ),
          onChanged: (value) {
            changed(value);
            _queueSave(text: true);
          },
          onEditingComplete: () {
            FocusScope.of(context).unfocus();
            unawaited(_flushSaves());
          },
        ),
        if (helper != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SettingDescription(helper),
          ),
      ],
    ),
  );

  Widget _fixedChoices({bool multiple = false, bool judgment = false}) {
    final name = judgment
        ? 'fixedJudgment'
        : multiple
        ? 'fixedMultiple'
        : 'fixedSingle';
    final current = judgment
        ? _draft!.fixedJudgmentAnswer
        : multiple
        ? _draft!.fixedMultipleAnswer
        : _draft!.fixedSingleAnswer;
    final valid = multiple
        ? RegExp(r'^[A-D]+$').hasMatch(current) &&
              current.split('').toSet().length == current.length
        : RegExp(judgment ? r'^[AB]$' : r'^[A-D]$').hasMatch(current);
    return Padding(
      key: ValueKey('input-$name'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            judgment
                ? '判断答案'
                : multiple
                ? '多选 / 投票答案'
                : '单选答案',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final option in judgment ? ['A', 'B'] : ['A', 'B', 'C', 'D'])
                if (multiple)
                  FilterChip(
                    key: ValueKey('$name-$option'),
                    label: Text(option),
                    selected: valid && current.contains(option),
                    onSelected: _disabled
                        ? null
                        : (selected) => _edit(() {
                            final choices = valid
                                ? current.split('').toSet()
                                : <String>{};
                            selected
                                ? choices.add(option)
                                : choices.remove(option);
                            _draft!.fixedMultipleAnswer =
                                (choices.toList()..sort()).join();
                          }),
                  )
                else
                  ChoiceChip(
                    key: ValueKey('$name-$option'),
                    label: Text(
                      judgment
                          ? option == 'A'
                                ? '正确'
                                : '错误'
                          : option,
                    ),
                    selected: current == option,
                    onSelected: _disabled
                        ? null
                        : (_) => _edit(() {
                            if (judgment) {
                              _draft!.fixedJudgmentAnswer = option;
                            } else {
                              _draft!.fixedSingleAnswer = option;
                            }
                          }),
                  ),
            ],
          ),
          const SizedBox(height: 4),
          SettingDescription(multiple ? '选择一个或多个选项' : '选择一个选项'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (_draft == null ||
          !identical(_source, c.settings) && !_dirty && !_saving) {
        _readSettings(c.settings);
      } else if (c.initialized && !_seenInitialized) {
        _scheduleModels();
      }
      _seenInitialized = c.initialized;
      final settings = _draft!;
      final windows = _windows;
      final hasAutomation = settings.autoEnter || settings.autoAnswer;
      final showAppAutoStart = c.systemServiceSupported || windows;
      return PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, _) => unawaited(_leave(didPop)),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('自动化'),
            actions: [
              if (_saving)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Icon(Icons.sync_rounded, size: 22),
                ),
            ],
            bottom: _saveError == null
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(66),
                    child: Padding(
                      key: const ValueKey('automation-save-error'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: Theme.of(context).colorScheme.error,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '未保存：$_saveError${c.settings.autoAnswer ? '；当前${c.settings.answerMode == AnswerMode.fixed ? '固定内容' : 'AI'}答题设置仍生效' : ''}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            tooltip: '重试自动保存',
                            onPressed: () => unawaited(_flushSaves()),
                            icon: const Icon(Icons.refresh_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          body: SettingsList(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (c.systemServiceSupported)
                        SwitchListTile(
                          key: const ValueKey('auto-start-service'),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 4,
                          ),
                          secondary: _settingIcon(
                            Icons.power_settings_new_rounded,
                          ),
                          title: const Text('自动启动服务'),
                          subtitle: SettingDescription('启用自动化时自动启动后台服务'),
                          value: settings.autoStartService,
                          onChanged:
                              _disabled ||
                                  !c.systemServiceSupported ||
                                  !(settings.autoEnter || settings.autoAnswer)
                              ? null
                              : (value) => _edit(() {
                                  settings.autoStartService = value;
                                  if (!value) settings.appAutoStart = false;
                                }, control: 'autoStartService'),
                        )
                      else
                        ListTile(
                          key: const ValueKey('auto-start-service'),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 4,
                          ),
                          leading: _settingIcon(
                            Icons.power_settings_new_rounded,
                          ),
                          title: const Text('自动启动服务'),
                          subtitle: SettingDescription(
                            windows ? '自动化随应用运行，无需单独启动服务' : '当前平台需保持应用前台运行',
                          ),
                          trailing: Icon(
                            windows
                                ? Icons.check_circle_outline_rounded
                                : Icons.info_outline_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      if (showAppAutoStart) ...[
                        const Divider(height: 1),
                        SwitchListTile(
                          key: const ValueKey('app-auto-start'),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 4,
                          ),
                          secondary: _settingIcon(Icons.restart_alt_rounded),
                          title: const Text('应用自启动'),
                          subtitle: SettingDescription(
                            windows
                                ? _windowsAutostartDescription
                                : !settings.autoStartService
                                ? '请在启用自动启动服务后开启'
                                : '开机后恢复自动化，需在系统中允许自启动',
                          ),
                          value: settings.appAutoStart,
                          onChanged:
                              _disabled ||
                                  !hasAutomation ||
                                  windows &&
                                      !_windowsAutostartAllowed &&
                                      !settings.appAutoStart ||
                                  c.systemServiceSupported &&
                                      !settings.autoStartService
                              ? null
                              : _setAppAutoStart,
                        ),
                      ],
                      const Divider(height: 1),
                      SwitchListTile(
                        key: const ValueKey('auto-enter'),
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        secondary: _settingIcon(Icons.how_to_reg_outlined),
                        title: const Text('自动签到'),
                        subtitle: const SettingDescription('发现正在上课的课堂后自动进入并签到'),
                        value: settings.autoEnter,
                        onChanged: _disabled
                            ? null
                            : (value) {
                                _edit(() {
                                  settings.autoEnter = value;
                                  if (!settings.autoEnter &&
                                      !settings.autoAnswer) {
                                    settings.autoStartService = false;
                                    settings.appAutoStart = false;
                                  }
                                }, control: 'autoEnter');
                              },
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        key: const ValueKey('auto-answer'),
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        secondary: _settingIcon(Icons.auto_awesome_outlined),
                        title: const Text('自动答题'),
                        subtitle: const SettingDescription('按固定内容或 AI 生成答案'),
                        value: settings.autoAnswer,
                        onChanged: _disabled
                            ? null
                            : (value) {
                                _edit(() {
                                  settings.autoAnswer = value;
                                  if (!settings.autoEnter &&
                                      !settings.autoAnswer) {
                                    settings.autoStartService = false;
                                    settings.appAutoStart = false;
                                  }
                                  _scheduleModels();
                                }, control: 'autoAnswer');
                              },
                      ),
                      if (c.backgroundWarning != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  c.backgroundWarning!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (settings.autoAnswer) ...[
                        const Divider(height: 1),
                        SwitchListTile(
                          key: const ValueKey('auto-submit'),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 4,
                          ),
                          secondary: _settingIcon(Icons.send_outlined),
                          title: const Text('自动提交'),
                          subtitle: const SettingDescription('关闭时仅填入答案，由你确认提交'),
                          value: settings.autoSubmit,
                          onChanged: _disabled
                              ? null
                              : (value) => _edit(
                                  () => settings.autoSubmit = value,
                                  control: 'autoSubmit',
                                ),
                        ),
                        if (settings.autoSubmit)
                          Padding(
                            key: const ValueKey('input-submitDelay'),
                            padding: const EdgeInsets.only(top: 8, bottom: 8),
                            child: TextField(
                              key: const ValueKey('field-submitDelay'),
                              enabled: !_disabled,
                              controller: _field(
                                'submitDelay',
                                '${settings.autoSubmitDelaySeconds}',
                              ),
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                labelText: '提交延迟',
                                suffixText: '秒',
                                helperText: '答案生成后等待的时间，1–3600 秒',
                                helperMaxLines: 3,
                                prefixIcon: Icon(Icons.timer_outlined),
                              ),
                              onChanged: (value) => _edit(
                                () => settings.autoSubmitDelaySeconds =
                                    int.tryParse(value) ?? 0,
                                text: true,
                              ),
                              onEditingComplete: () {
                                FocusScope.of(context).unfocus();
                                unawaited(_flushSaves());
                              },
                            ),
                          ),
                        const SizedBox(height: 8),
                        SegmentedButton<AnswerMode>(
                          key: const ValueKey('answer-mode'),
                          segments: const [
                            ButtonSegment(
                              value: AnswerMode.fixed,
                              label: Text('固定内容'),
                              icon: Icon(Icons.notes_outlined),
                            ),
                            ButtonSegment(
                              value: AnswerMode.ai,
                              label: Text('自定义 AI'),
                              icon: Icon(Icons.auto_awesome_outlined),
                            ),
                          ],
                          selected: {settings.answerMode},
                          onSelectionChanged: _disabled
                              ? null
                              : (selection) {
                                  _edit(() {
                                    settings.answerMode = selection.first;
                                    _scheduleModels();
                                  });
                                },
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: SettingDescription('选择答案生成方式'),
                        ),
                        const SizedBox(height: 16),
                        if (settings.answerMode == AnswerMode.fixed) ...[
                          _fixedChoices(),
                          _fixedChoices(multiple: true),
                          _fixedChoices(judgment: true),
                          _input(
                            'fixedSubjective',
                            '主观 / 填空答案',
                            settings.fixedSubjectiveAnswer,
                            (value) => settings.fixedSubjectiveAnswer = value,
                            lines: 3,
                            helper: '每个空使用相同内容',
                            icon: Icons.notes_outlined,
                          ),
                        ] else ...[
                          _input(
                            'baseUrl',
                            'base_url',
                            settings.baseUrl,
                            (value) => setState(() {
                              settings.baseUrl = value.trim();
                              _scheduleModels(clearSelection: true);
                            }),
                            hint: 'https://api.example.com/v1',
                            helper: 'OpenAI 兼容接口地址',
                            icon: Icons.cloud_outlined,
                          ),
                          _input(
                            'apiKey',
                            'api_key',
                            settings.apiKey,
                            (value) => setState(() {
                              settings.apiKey = value.trim();
                              _scheduleModels(clearSelection: true);
                            }),
                            secret: true,
                            helper: '仅保存在本机，用于调用模型',
                            icon: Icons.key_outlined,
                          ),
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'models-$_modelGeneration-${settings.model}',
                            ),
                            initialValue: _models.contains(settings.model)
                                ? settings.model
                                : null,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: '模型',
                              hintText: _loadingModels
                                  ? '正在获取模型…'
                                  : '填写地址和密钥后自动获取',
                              prefixIcon: const Icon(Icons.memory_outlined),
                              suffixIcon: _loadingModels
                                  ? const Padding(
                                      padding: EdgeInsets.all(14),
                                      child: SizedBox.square(
                                        dimension: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      tooltip: '刷新模型列表',
                                      onPressed:
                                          _disabled ||
                                              settings.baseUrl.isEmpty ||
                                              settings.apiKey.isEmpty
                                          ? null
                                          : () => setState(
                                              () => _scheduleModels(
                                                immediate: true,
                                              ),
                                            ),
                                      icon: const Icon(Icons.refresh),
                                    ),
                            ),
                            items: _models
                                .map(
                                  (model) => DropdownMenuItem(
                                    value: model,
                                    child: Text(
                                      model,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: _disabled || !_modelsLoaded
                                ? null
                                : (model) {
                                    if (model != null) {
                                      _edit(() {
                                        settings.model = model;
                                        _defaultModelSelected = false;
                                      });
                                    }
                                  },
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: SettingDescription(
                              _defaultModelSelected
                                  ? '已选择首个模型，可切换'
                                  : '从服务商获取，点击刷新重新加载',
                            ),
                          ),
                          if (_modelsError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _modelsError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          _input(
                            'prompt',
                            '提示词',
                            settings.customPrompt,
                            (value) => settings.customPrompt = value,
                            lines: 4,
                            helper: '{question} 自动替换为题目',
                            icon: Icons.edit_note_outlined,
                          ),
                          DropdownButtonFormField<SlideScope>(
                            key: const ValueKey('slide-scope'),
                            initialValue: settings.slideScope,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '发送课件',
                              prefixIcon: Icon(Icons.photo_library_outlined),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: SlideScope.none,
                                child: Text(
                                  '不发送课件',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              DropdownMenuItem(
                                value: SlideScope.current,
                                child: Text(
                                  '当前页课件',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              DropdownMenuItem(
                                value: SlideScope.currentAndNext,
                                child: Text(
                                  '当前页和后一页课件',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              DropdownMenuItem(
                                value: SlideScope.all,
                                child: Text(
                                  '完整课件',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            onChanged: _disabled
                                ? null
                                : (value) {
                                    if (value != null) {
                                      _edit(() => settings.slideScope = value);
                                    }
                                  },
                          ),
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: SettingDescription('仅向所选 AI 服务发送指定范围的课件'),
                          ),
                          const SizedBox(height: 12),
                          if (settings.slideScope != SlideScope.none)
                            _input(
                              'slidePrompt',
                              '课件额外提示词',
                              settings.slidePrompt,
                              (value) => settings.slidePrompt = value,
                              lines: 3,
                              helper: '发送课件时追加在原提示词之后',
                              icon: Icons.note_add_outlined,
                            ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
