import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../domain/models.dart';
import '../services/ai_answer.dart';
import '../services/app_logs.dart';

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
      'fixed': source.fixedAnswer,
      'baseUrl': source.baseUrl,
      'apiKey': source.apiKey,
      'prompt': source.customPrompt,
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

  Widget _settingIcon(IconData icon, {bool account = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: account ? 44 : 34,
      height: account ? 44 : 34,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(account ? 14 : 10),
      ),
      child: Icon(icon, size: account ? 26 : 20, color: scheme.primary),
    );
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
    child: TextField(
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
        helperText: helper,
        helperMaxLines: 2,
        prefixIcon: icon == null ? null : Icon(icon),
      ),
      onChanged: changed,
      onEditingComplete: () => FocusScope.of(context).unfocus(),
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
      return Scaffold(
        appBar: AppBar(title: const Text('自动化')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: _settingIcon(Icons.how_to_reg_outlined),
                      title: const Text('自动签到'),
                      value: settings.autoEnter,
                      onChanged: _disabled
                          ? null
                          : (value) {
                              setState(() => settings.autoEnter = value);
                            },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: _settingIcon(Icons.auto_awesome_outlined),
                      title: const Text('自动答题'),
                      value: settings.autoAnswer,
                      onChanged: _disabled
                          ? null
                          : (value) {
                              setState(() {
                                settings.autoAnswer = value;
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
                        contentPadding: EdgeInsets.zero,
                        secondary: _settingIcon(Icons.send_outlined),
                        title: const Text('自动提交'),
                        subtitle: const Text('关闭时仅填入答案，确认后提交'),
                        value: settings.autoSubmit,
                        onChanged: _disabled
                            ? null
                            : (value) =>
                                  setState(() => settings.autoSubmit = value),
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
                      const SizedBox(height: 16),
                      if (settings.answerMode == AnswerMode.fixed)
                        _input(
                          'fixed',
                          '固定答案',
                          settings.fixedAnswer,
                          (value) => settings.fixedAnswer = value,
                          lines: 3,
                          hint: '选择题填 A 或 AB；填空题每行一个答案',
                        )
                      else ...[
                        _input(
                          'baseUrl',
                          'base_url',
                          settings.baseUrl,
                          (value) => setState(() {
                            settings.baseUrl = value.trim();
                            _scheduleModels(clearSelection: true);
                          }),
                          hint: 'https://api.example.com/v1',
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
                          icon: Icons.key_outlined,
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
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
                                  helperText: _defaultModelSelected
                                      ? '已选择首个模型，可切换'
                                      : null,
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
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 4, top: 4),
                              child: _loadingModels
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 24,
                                        height: 24,
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
                          ],
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
                          helper: '{question} 替换为题目；没有占位符时会自动追加题目',
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
                              child: Text('不发送课件'),
                            ),
                            DropdownMenuItem(
                              value: SlideScope.current,
                              child: Text('当前页课件'),
                            ),
                            DropdownMenuItem(
                              value: SlideScope.currentAndNext,
                              child: Text('当前页和后一页课件'),
                            ),
                            DropdownMenuItem(
                              value: SlideScope.all,
                              child: Text('完整课件'),
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
                        const SizedBox(height: 12),
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
