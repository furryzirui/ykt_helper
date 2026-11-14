import 'dart:async';

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

class _AutomationPageState extends State<AutomationPage> {
  final _fields = <String, TextEditingController>{};
  bool _saving = false, _seenInitialized = false;
  AppSettings? _draft, _source;
  Timer? _modelDebounce;
  int _modelGeneration = 0;
  bool _loadingModels = false, _defaultModelSelected = false;
  List<String> _models = [];
  String? _modelsError, _loadedBaseUrl, _loadedApiKey;
  bool get _disabled => _saving || !widget.controller.initialized;
  bool get _modelsReady =>
      !_loadingModels &&
      _loadedBaseUrl == _draft?.baseUrl.trim() &&
      _loadedApiKey == _draft?.apiKey.trim() &&
      _models.contains(_draft?.model);

  @override
  void initState() {
    super.initState();
    final cached = widget.draft;
    if (cached?.settings != null &&
        identical(cached?.source, widget.controller.settings)) {
      _draft = cached!.settings;
      _source = cached.source;
    }
  }

  void _readSettings(AppSettings source) {
    _source = source;
    _draft = AppSettings.fromJson(source.toJson());
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
        if (!models.contains(_draft!.model)) {
          _draft!.model = models.first;
          _defaultModelSelected = true;
        }
      });
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
      setState(() => _draft!.appAutoStart = false);
      return;
    }
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('应用自启动'),
        content: Text(
          windows
              ? '用于登录 Windows 后在后台启动自动化。\n\n保存设置后生效，可在“应用权限 → 自启动”或系统“启动应用”中管理。退出应用后，自动化将在下次登录 Windows 时恢复。'
              : '用于开机后以及系统允许的进程回收后恢复自动化。\n\n保存设置后，请在“应用权限 → 自启动”中允许自启动，并允许通知、取消电池优化。强行停止应用或系统禁止自启动后无法自动恢复。',
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
      setState(() => _draft!.appAutoStart = true);
    }
  }

  @override
  void dispose() {
    widget.draft?.settings = _draft;
    widget.draft?.source = _source;
    _modelDebounce?.cancel();
    _modelGeneration++;
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<bool> _save() async {
    if (_saving) return false;
    if (_draft!.autoAnswer &&
        _draft!.autoSubmit &&
        (_draft!.autoSubmitDelaySeconds < 1 ||
            _draft!.autoSubmitDelaySeconds > 3600)) {
      _showError('提交延迟请输入 1–3600 秒');
      return false;
    }
    if (_draft!.autoAnswer &&
        _draft!.answerMode == AnswerMode.ai &&
        !_modelsReady) {
      _showError('请先获取并选择当前 AI 服务的模型');
      return false;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.saveSettings(_draft!);
      if (!mounted) return true;
      _readSettings(widget.controller.settings);
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
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
          onChanged: changed,
          onEditingComplete: () => FocusScope.of(context).unfocus(),
        ),
        if (helper != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SettingDescription(helper),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (_draft == null || !identical(_source, c.settings) && !_saving) {
        _readSettings(c.settings);
      } else if (c.initialized && !_seenInitialized) {
        _scheduleModels();
      }
      _seenInitialized = c.initialized;
      final settings = _draft!;
      final windows = defaultTargetPlatform == TargetPlatform.windows;
      final hasAutomation = settings.autoEnter || settings.autoAnswer;
      final showAppAutoStart =
          c.systemServiceSupported && settings.autoStartService ||
          windows && hasAutomation;
      return Scaffold(
        appBar: AppBar(title: const Text('自动化')),
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
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
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
                            : (value) => setState(() {
                                settings.autoStartService = value;
                                if (!value) settings.appAutoStart = false;
                              }),
                      )
                    else
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        leading: _settingIcon(Icons.power_settings_new_rounded),
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
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        secondary: _settingIcon(Icons.restart_alt_rounded),
                        title: const Text('应用自启动'),
                        subtitle: SettingDescription(
                          windows
                              ? '登录 Windows 后在后台启动自动化'
                              : '开机后恢复自动化，需在系统中允许自启动',
                        ),
                        value: settings.appAutoStart,
                        onChanged: _disabled ? null : _setAppAutoStart,
                      ),
                    ],
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      secondary: _settingIcon(Icons.how_to_reg_outlined),
                      title: const Text('自动签到'),
                      subtitle: const SettingDescription('发现正在上课的课堂后自动进入并签到'),
                      value: settings.autoEnter,
                      onChanged: _disabled
                          ? null
                          : (value) {
                              setState(() {
                                settings.autoEnter = value;
                                if (!settings.autoEnter &&
                                    !settings.autoAnswer) {
                                  settings.autoStartService = false;
                                  settings.appAutoStart = false;
                                }
                              });
                            },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      secondary: _settingIcon(Icons.auto_awesome_outlined),
                      title: const Text('自动答题'),
                      subtitle: const SettingDescription('按固定内容或 AI 生成答案'),
                      value: settings.autoAnswer,
                      onChanged: _disabled
                          ? null
                          : (value) {
                              setState(() {
                                settings.autoAnswer = value;
                                if (!settings.autoEnter &&
                                    !settings.autoAnswer) {
                                  settings.autoStartService = false;
                                  settings.appAutoStart = false;
                                }
                                _scheduleModels();
                              });
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
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        secondary: _settingIcon(Icons.send_outlined),
                        title: const Text('自动提交'),
                        subtitle: const SettingDescription('关闭时仅填入答案，由你确认提交'),
                        value: settings.autoSubmit,
                        onChanged: _disabled
                            ? null
                            : (value) =>
                                  setState(() => settings.autoSubmit = value),
                      ),
                      if (settings.autoSubmit)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: TextField(
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
                            onChanged: (value) =>
                                settings.autoSubmitDelaySeconds =
                                    int.tryParse(value) ?? 0,
                            onEditingComplete: () =>
                                FocusScope.of(context).unfocus(),
                          ),
                        ),
                      const SizedBox(height: 8),
                      SegmentedButton<AnswerMode>(
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
                                setState(() {
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
                        _input(
                          'fixedSingle',
                          '单选 / 判断答案',
                          settings.fixedSingleAnswer,
                          (value) => settings.fixedSingleAnswer = value,
                          hint: 'A',
                          helper: '填写一个选项字母，如 A',
                          icon: Icons.radio_button_checked_rounded,
                        ),
                        _input(
                          'fixedMultiple',
                          '多选 / 投票答案',
                          settings.fixedMultipleAnswer,
                          (value) => settings.fixedMultipleAnswer = value,
                          hint: 'AB',
                          helper: '填写多个选项字母，如 AB',
                          icon: Icons.checklist_rounded,
                        ),
                        _input(
                          'fixedSubjective',
                          '主观 / 填空答案',
                          settings.fixedSubjectiveAnswer,
                          (value) => settings.fixedSubjectiveAnswer = value,
                          lines: 3,
                          helper: '填空题每行一个答案',
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
                          onChanged: _disabled || !_modelsReady
                              ? null
                              : (model) {
                                  if (model != null) {
                                    setState(() {
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
                                    setState(() => settings.slideScope = value);
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
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _disabled
                  ? null
                  : () async {
                      final success = await _save();
                      if (success && context.mounted) {
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            const SnackBar(content: Text('设置已保存')),
                          );
                      }
                    },
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 20),
              label: Text(_saving ? '保存中…' : '保存设置'),
            ),
          ],
        ),
      );
    },
  );
}
