import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app/app_controller.dart';
import '../domain/models.dart' as domain;
import '../services/app_permissions.dart';
import 'permissions_page.dart';
import 'login_page.dart';
import 'widgets.dart';

class LiveListPage extends StatefulWidget {
  final AppController controller;
  const LiveListPage({super.key, required this.controller});
  @override
  State<LiveListPage> createState() => _LiveListPageState();
}

class _LiveListPageState extends State<LiveListPage> {
  String? _entering;
  Future<void> _open(domain.Lesson lesson) async {
    setState(() => _entering = lesson.id);
    try {
      final live = await widget.controller.enter(lesson);
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                LivePage(controller: widget.controller, classroom: live),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _entering = null);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => widget.controller.account == null
        ? ContentMessage(
            '未登录',
            actionLabel: '登录',
            retry: !widget.controller.initialized
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LoginPage(controller: widget.controller),
                    ),
                  ),
          )
        : widget.controller.liveLessons.isEmpty
        ? RefreshIndicator(
            onRefresh: widget.controller.refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 100),
                ContentMessage('暂无正在上课的课堂'),
              ],
            ),
          )
        : RefreshIndicator(
            onRefresh: widget.controller.refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: widget.controller.liveLessons.length,
              itemBuilder: (context, index) {
                final lesson = widget.controller.liveLessons[index];
                final live = widget.controller.classrooms.values
                    .where((item) => item.lesson.id == lesson.id)
                    .firstOrNull;
                return Card(
                  margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        StatusLine(
                          icon: Icons.class_outlined,
                          text: lesson.title,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                live?.connectionLabel ??
                                    formatTime(lesson.startedAt),
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (_entering == lesson.id)
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else
                              FilledButton(
                                onPressed: _entering == null
                                    ? () => _open(lesson)
                                    : null,
                                child: Text(live == null ? '签到进入' : '查看课堂'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
  );
}

class LivePage extends StatefulWidget {
  final AppController controller;
  final LiveClass classroom;
  const LivePage({
    super.key,
    required this.controller,
    required this.classroom,
  });
  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  bool _locationBusy = false, _exporting = false, _refreshing = false;
  String? _locationMessage;
  Future<void> _checkin() async {
    setState(() {
      _locationBusy = true;
      _locationMessage = null;
    });
    try {
      final status = await widget.controller.locationStatus(widget.classroom);
      if (!mounted) return;
      if (status.signed) {
        setState(() => _locationMessage = '位置已签到');
        return;
      }
      if (!status.available) {
        setState(() => _locationMessage = '当前没有进行中的位置签到');
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认位置签到'),
          content: Text(
            '${status.address.isEmpty ? '地址未提供' : status.address}\n'
            '纬度：${status.latitude ?? '未提供'}\n经度：${status.longitude ?? '未提供'}\n\n'
            '使用服务器签到中心，并非手机定位',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认签到'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final success = await widget.controller.confirmLocation(
        widget.classroom,
        status,
      );
      if (mounted) {
        setState(() => _locationMessage = success ? '位置签到成功' : '位置签到未完成');
      }
    } catch (error) {
      if (mounted) setState(() => _locationMessage = error.toString());
    } finally {
      if (mounted) setState(() => _locationBusy = false);
    }
  }

  Future<void> _export(String format) async {
    final origin = shareOrigin(context);
    final presentation = widget.classroom.currentPresentation;
    if (presentation == null) return;
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      if (format == 'image' || format == 'album') {
        if (!await ensureAppPermission(context, AppPermission.photos) ||
            !mounted) {
          return;
        }
      }
      if (format == 'image') {
        final slide = widget.classroom.currentSlide;
        if (slide != null) {
          await widget.controller.saveSlide(slide);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  defaultTargetPlatform == TargetPlatform.windows
                      ? '图片已保存'
                      : '已保存到系统相册',
                ),
              ),
            );
          }
        }
      } else if (format == 'album') {
        final count = await widget.controller.saveSlidesToGallery(
          presentation.slides,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                defaultTargetPlatform == TargetPlatform.windows
                    ? '已保存 $count 张图片'
                    : '已保存 $count 张图片到系统相册',
              ),
            ),
          );
        }
      } else {
        await widget.controller.exportSlides(
          presentation,
          pptx: format == 'pptx',
          sharePositionOrigin: origin,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _wideLive(LiveClass live, BoxConstraints constraints) {
    final presentation = live.currentPresentation;
    final question = live.currentQuestion;
    final panelWidth = (constraints.maxWidth * .34).clamp(280.0, 400.0);
    return Row(
      key: const ValueKey('live-wide-layout'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (presentation != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      presentation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: const Text('跟随教师翻页'),
                    value: live.followTeacher,
                    onChanged: (value) =>
                        widget.controller.followTeacher(live, value),
                  ),
                Expanded(child: SlideViewport(live.currentSlide)),
                if (presentation != null && presentation.slides.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '上一页',
                        onPressed: live.slideIndex > 0
                            ? () => widget.controller.selectSlide(
                                live,
                                live.slideIndex - 1,
                              )
                            : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '${live.slideIndex + 1} / ${presentation.slides.length}',
                      ),
                      IconButton(
                        tooltip: '下一页',
                        onPressed:
                            live.slideIndex + 1 < presentation.slides.length
                            ? () => widget.controller.selectSlide(
                                live,
                                live.slideIndex + 1,
                              )
                            : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                  if (constraints.maxHeight >= 440)
                    SizedBox(
                      height: 92,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: presentation.slides.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(width: 8),
                        itemBuilder: (context, index) => SizedBox(
                          width: 120,
                          child: SlideThumbnail(
                            key: ValueKey('live-thumbnail-$index'),
                            slide: presentation.slides[index],
                            page: index + 1,
                            selected: index == live.slideIndex,
                            onTap: () =>
                                widget.controller.selectSlide(live, index),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: panelWidth,
          child: ListView(
            primary: false,
            padding: const EdgeInsets.fromLTRB(12, 8, 16, 20),
            children: [
              StatusLine(
                icon: live.ended ? Icons.stop_circle_outlined : Icons.sensors,
                text: live.ended ? '课堂已结束' : live.connectionLabel,
              ),
              const SizedBox(height: 12),
              StatusLine(
                icon: Icons.how_to_reg_outlined,
                text: '本节签到：${live.checkinText}',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _locationBusy || live.ended ? null : _checkin,
                icon: const Icon(Icons.location_on_outlined),
                label: Text(
                  _locationBusy
                      ? '签到中…'
                      : live.location?.signed == true
                      ? '位置已签到'
                      : '位置签到',
                ),
              ),
              for (final message in [
                live.attendanceError,
                _locationMessage,
                live.error,
                widget.controller.backgroundWarning,
                if (live.answerSyncError != null)
                  '作答状态未能同步：${live.answerSyncError}',
              ])
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              if (_exporting)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (question != null)
                QuestionCard(
                  key: ValueKey(question.id),
                  controller: widget.controller,
                  classroom: live,
                  question: question,
                ),
              if (live.questions.isNotEmpty) ...[
                const Divider(height: 24),
                Text('课堂题目', style: Theme.of(context).textTheme.titleMedium),
                for (final question in live.questions.values)
                  ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(
                      '${question.typeLabel} · ${live.answers.containsKey(question.id)
                          ? '已提交'
                          : live.answersKnown
                          ? '暂无作答记录'
                          : '状态未同步'}',
                    ),
                    subtitle: live.autoStates[question.id] == null
                        ? null
                        : Text(live.autoStates[question.id]!),
                    children: [
                      QuestionCard(
                        key: ValueKey('list-${question.id}'),
                        controller: widget.controller,
                        classroom: live,
                        question: question,
                      ),
                    ],
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final live = widget.classroom,
          presentation = live.currentPresentation,
          slide = live.currentSlide;
      return Scaffold(
        appBar: fullTitleAppBar(
          context,
          title: live.lesson.title,
          actions: [
            IconButton(
              tooltip: '刷新课堂',
              onPressed: _refreshing
                  ? null
                  : () async {
                      setState(() => _refreshing = true);
                      try {
                        await widget.controller.refreshClassroom(live);
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(error.toString())),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _refreshing = false);
                      }
                    },
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '同步我的答案',
              onPressed: live.syncingAnswers
                  ? null
                  : () => widget.controller.syncAnswers(live),
              icon: const Icon(Icons.sync),
            ),
            PopupMenuButton<String>(
              tooltip: '导出课件',
              icon: const Icon(Icons.download_outlined),
              enabled: presentation != null && !_exporting,
              onSelected: _export,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'image',
                  child: Text(
                    defaultTargetPlatform == TargetPlatform.windows
                        ? '保存当前页图片'
                        : '当前页保存到系统相册',
                  ),
                ),
                PopupMenuItem(
                  value: 'album',
                  child: Text(
                    defaultTargetPlatform == TargetPlatform.windows
                        ? '保存全部图片'
                        : '全部保存到系统相册',
                  ),
                ),
                const PopupMenuItem(value: 'zip', child: Text('导出全部图片 ZIP')),
                const PopupMenuItem(value: 'pptx', child: Text('导出完整 PPTX')),
              ],
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) => useWideClassroom(constraints)
              ? _wideLive(live, constraints)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: StatusLine(
                            icon: live.ended
                                ? Icons.stop_circle_outlined
                                : Icons.sensors,
                            text: live.ended ? '课堂已结束' : live.connectionLabel,
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _locationBusy || live.ended
                              ? null
                              : _checkin,
                          icon: const Icon(Icons.location_on_outlined),
                          label: Text(
                            _locationBusy
                                ? '签到中…'
                                : live.location?.signed == true
                                ? '位置已签到'
                                : '位置签到',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    StatusLine(
                      icon: Icons.how_to_reg_outlined,
                      text: '本节签到：${live.checkinText}',
                    ),
                    if (live.attendanceError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          live.attendanceError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_locationMessage != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(_locationMessage!),
                      ),
                    if (live.error != null)
                      Text(
                        live.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (widget.controller.backgroundWarning != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          widget.controller.backgroundWarning!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (live.answerSyncError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '作答状态未能同步：${live.answerSyncError}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_exporting)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (presentation != null) ...[
                      Text(
                        presentation.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('跟随教师翻页'),
                        value: live.followTeacher,
                        onChanged: (value) =>
                            widget.controller.followTeacher(live, value),
                      ),
                    ],
                    if (slide != null)
                      SlideImage(slide)
                    else
                      const SizedBox(
                        height: 200,
                        child: Center(child: Text('等待教师展示课件')),
                      ),
                    if (presentation != null && presentation.slides.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '上一页',
                            onPressed: live.slideIndex > 0
                                ? () => widget.controller.selectSlide(
                                    live,
                                    live.slideIndex - 1,
                                  )
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text(
                            '${live.slideIndex + 1} / ${presentation.slides.length}',
                          ),
                          IconButton(
                            tooltip: '下一页',
                            onPressed:
                                live.slideIndex + 1 < presentation.slides.length
                                ? () => widget.controller.selectSlide(
                                    live,
                                    live.slideIndex + 1,
                                  )
                                : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    if (live.currentQuestion != null)
                      QuestionCard(
                        key: ValueKey(live.currentQuestion!.id),
                        controller: widget.controller,
                        classroom: live,
                        question: live.currentQuestion!,
                      ),
                    if (live.questions.isNotEmpty) ...[
                      const Divider(height: 32),
                      Text(
                        '课堂题目',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final question in live.questions.values)
                        ExpansionTile(
                          title: Text(
                            '${question.typeLabel} · ${live.answers.containsKey(question.id)
                                ? '已提交'
                                : live.answersKnown
                                ? '暂无作答记录'
                                : '状态未同步'}',
                          ),
                          subtitle: live.autoStates[question.id] == null
                              ? null
                              : Text(live.autoStates[question.id]!),
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: QuestionCard(
                                key: ValueKey('list-${question.id}'),
                                controller: widget.controller,
                                classroom: live,
                                question: question,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ],
                ),
        ),
      );
    },
  );
}

class QuestionCard extends StatefulWidget {
  final AppController controller;
  final LiveClass classroom;
  final domain.Question question;
  const QuestionCard({
    super.key,
    required this.controller,
    required this.classroom,
    required this.question,
  });
  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final _choice = <String>{};
  final _text = TextEditingController();
  final _blanks = <TextEditingController>[];
  final _pics = <domain.Json>[];
  bool _submitting = false, _uploading = false;
  String? _error;
  String? _appliedDraft;
  Timer? _timer;
  bool get _optionQuestion =>
      widget.question.isJudgment || [1, 2, 3, 6].contains(widget.question.type);
  bool get _multipleOptionQuestion =>
      !widget.question.isJudgment &&
      (widget.question.type == 2 ||
          widget.question.type == 3 && widget.question.selectionLimit > 1);
  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.question.blankCount; i++) {
      _blanks.add(TextEditingController());
    }
    _readDraft();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant QuestionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _readDraft();
    _choice.removeWhere((key) => !widget.question.options.containsKey(key));
    if (!_multipleOptionQuestion && _choice.length > 1) {
      final first = _choice.first;
      _choice
        ..clear()
        ..add(first);
    }
  }

  void _readDraft() {
    final draft = widget.classroom.draftAnswers[widget.question.id];
    if (draft == null) {
      _appliedDraft = null;
      return;
    }
    final fingerprint = jsonEncode(draft);
    if (_appliedDraft == fingerprint) return;
    _appliedDraft = fingerprint;
    if (_optionQuestion && draft is List) {
      final selections = draft
          .map(domain.str)
          .where(widget.question.options.containsKey);
      _choice
        ..clear()
        ..addAll(_multipleOptionQuestion ? selections : selections.take(1));
    } else if (widget.question.type == 4 && draft is List) {
      for (var i = 0; i < _blanks.length; i++) {
        _blanks[i].text = i < draft.length ? domain.str(draft[i]) : '';
      }
    } else if (widget.question.type == 5 && draft is Map) {
      _text.text = domain.str(draft['content']);
      _pics
        ..clear()
        ..addAll(domain.array(draft['pics']).map(domain.object));
    }
  }

  void _draftEdited() {
    final question = widget.question;
    final dynamic answer;
    if (_optionQuestion) {
      answer = _choice.toList()..sort();
    } else if (question.type == 4) {
      answer = _blanks.map((blank) => blank.text.trim()).toList();
    } else {
      answer = {
        'content': _text.text.trim(),
        'pics': List<domain.Json>.of(_pics),
        'videos': <dynamic>[],
      };
    }
    _appliedDraft = jsonEncode(answer);
    widget.controller.updateAnswerDraft(widget.classroom, question, answer);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    for (final blank in _blanks) {
      blank.dispose();
    }
    super.dispose();
  }

  int? get _remaining => widget.question.limit > 0 && widget.question.dt > 0
      ? ((widget.question.dt +
                    widget.question.limit * 1000 -
                    DateTime.now().millisecondsSinceEpoch -
                    widget.question.serverOffsetMillis) /
                1000)
            .ceil()
            .clamp(0, 86400)
      : null;
  Future<void> _upload() async {
    // Choosing an image is already a manual takeover; do not let a pending
    // automatic submission race the system picker or the upload request.
    _draftEdited();
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (image == null || !mounted) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final result = await widget.controller.uploadAnswerImage(
        widget.classroom,
        image.path,
      );
      if (mounted) {
        setState(() => _pics.add(result));
        _draftEdited();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _submit() async {
    final question = widget.question;
    dynamic answer;
    if (_optionQuestion) {
      if (_choice.isEmpty) {
        setState(() => _error = '请选择答案');
        return;
      }
      answer = _choice.toList()..sort();
    } else if (question.type == 4) {
      answer = _blanks.map((blank) => blank.text.trim()).toList();
      if ((answer as List<String>).every((value) => value.isEmpty)) {
        setState(() => _error = '请填写答案');
        return;
      }
    } else {
      if (_text.text.trim().isEmpty && _pics.isEmpty) {
        setState(() => _error = '请填写答案或添加图片');
        return;
      }
      answer = {
        'content': _text.text.trim(),
        'pics': _pics,
        'videos': <dynamic>[],
      };
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.submitAnswer(widget.classroom, question, answer);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.question, live = widget.classroom;
    final answer = live.answers[question.id];
    final active =
        !live.ended &&
        live.activeProblemIds.contains(question.id) &&
        (_remaining == null || _remaining! > 0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    question.typeLabel,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_remaining != null && active) Text('剩余 $_remaining 秒'),
              ],
            ),
            const SizedBox(height: 8),
            HtmlContent(question.body),
            if (answer != null) ...[
              for (final option in question.options.entries)
                HtmlContent('${option.key}. ${option.value}'),
              OwnAnswer(answer),
            ] else ...[
              if (!live.answersKnown)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('作答状态尚未确认。提交前请确认没有在其他设备作答。'),
                ),
              if (!active)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('当前不在答题时间内'),
                ),
              if (question.type == 3 && _multipleOptionQuestion)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('最多选择 ${question.selectionLimit} 项'),
                ),
              if (_optionQuestion)
                for (final option in question.options.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: HtmlContent('${option.key}. ${option.value}'),
                    value: _choice.contains(option.key),
                    onChanged: active && !_submitting
                        ? (selected) {
                            setState(() {
                              if (!_multipleOptionQuestion) _choice.clear();
                              if (selected == true) {
                                if (_multipleOptionQuestion &&
                                    question.type == 3 &&
                                    _choice.length >= question.selectionLimit) {
                                  _error = '最多选择 ${question.selectionLimit} 项';
                                  return;
                                }
                                _choice.add(option.key);
                              } else {
                                _choice.remove(option.key);
                              }
                              _error = null;
                            });
                            _draftEdited();
                          }
                        : null,
                  ),
              if (!_optionQuestion && question.type == 4)
                for (var i = 0; i < _blanks.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: TextField(
                      controller: _blanks[i],
                      enabled: active && !_submitting,
                      decoration: InputDecoration(labelText: '第 ${i + 1} 空'),
                      onChanged: (_) => _draftEdited(),
                    ),
                  ),
              if (!_optionQuestion && question.type == 5) ...[
                TextField(
                  controller: _text,
                  enabled: active && !_submitting,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(labelText: '答案'),
                  onChanged: (_) => _draftEdited(),
                ),
                for (var i = 0; i < _pics.length; i++)
                  ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text('图片 ${i + 1}'),
                    trailing: IconButton(
                      tooltip: '移除图片',
                      onPressed: _submitting
                          ? null
                          : () {
                              setState(() => _pics.removeAt(i));
                              _draftEdited();
                            },
                      icon: const Icon(Icons.close),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: active && !_uploading && !_submitting
                        ? _upload
                        : null,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(_uploading ? '上传中…' : '添加图片'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: active && !_submitting && !_uploading
                    ? _submit
                    : null,
                child: Text(_submitting ? '提交中…' : '提交答案'),
              ),
            ],
            if (live.autoStates[question.id] != null ||
                live.draftAnswers.containsKey(question.id))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(live.autoStates[question.id] ?? '答案已填充，待确认提交'),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
