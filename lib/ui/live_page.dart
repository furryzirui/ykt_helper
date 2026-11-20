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
  final _feedController = ScrollController(),
      _previewController = ScrollController();
  final _slideKeys = <String, GlobalKey>{},
      _thumbnailKeys = <String, GlobalKey>{};
  String? _followedPage;
  int _scrollRevision = 0;

  @override
  void dispose() {
    _scrollRevision++;
    _feedController.dispose();
    _previewController.dispose();
    super.dispose();
  }

  String _slideKey(LiveClass live, int index) =>
      '${live.presentationId}:$index';

  Future<void> _scrollToPage(
    LiveClass live,
    int page, {
    bool preview = false,
  }) async {
    final controller = preview ? _previewController : _feedController;
    final keys = preview ? _thumbnailKeys : _slideKeys;
    final revision = ++_scrollRevision;
    final slides = live.currentPresentation?.slides ?? <domain.Slide>[];
    if (page < 0 || page >= slides.length) return;
    for (var attempt = 0; attempt < 8; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || revision != _scrollRevision || !controller.hasClients) {
        return;
      }
      final target = keys[_slideKey(live, page)]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(target, alignment: 0.0);
        return;
      }
      // The feed lays out pages lazily. Use its measured visible pages to
      // approach the requested page, then align the actual rendered card.
      final rendered = <int>[];
      for (var index = 0; index < slides.length; index++) {
        if (keys[_slideKey(live, index)]?.currentContext != null) {
          rendered.add(index);
        }
      }
      final position = controller.position;
      final nearest = rendered.isEmpty
          ? 0
          : rendered.reduce(
              (a, b) => (a - page).abs() < (b - page).abs() ? a : b,
            );
      final step = preview
          ? 130.0
          : rendered.length > 1
          ? position.viewportDimension / (rendered.last - rendered.first + 1)
          : position.viewportDimension * .85;
      final offset = (position.pixels + (page - nearest) * step)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      if (offset == position.pixels) return;
      controller.jumpTo(offset);
    }
  }

  void _selectPage(LiveClass live, int page) {
    widget.controller.selectSlide(live, page);
    if (_feedController.hasClients) unawaited(_scrollToPage(live, page));
    if (_previewController.hasClients) {
      unawaited(_scrollToPage(live, page, preview: true));
    }
  }

  domain.Question? _questionFor(LiveClass live, domain.Slide slide) {
    final question = slide.question;
    return question == null ? null : live.questions[question.id] ?? question;
  }

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

  Future<void> _export(String format, {domain.Slide? selectedSlide}) async {
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
        final slide = selectedSlide ?? widget.classroom.currentSlide;
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

  Widget _summary(LiveClass live) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          if (live.currentPresentation != null) ...[
            const Divider(height: 20),
            Text(
              live.currentPresentation!.title,
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
        ],
      ),
    ),
  );

  Widget _pageControls(LiveClass live, domain.Presentation presentation) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: '上一页',
        onPressed: live.slideIndex > 0
            ? () => _selectPage(live, live.slideIndex - 1)
            : null,
        icon: const Icon(Icons.chevron_left),
      ),
      Text('${live.slideIndex + 1} / ${presentation.slides.length}'),
      IconButton(
        tooltip: '下一页',
        onPressed: live.slideIndex + 1 < presentation.slides.length
            ? () => _selectPage(live, live.slideIndex + 1)
            : null,
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  void _followPage(LiveClass live, {required bool preview}) {
    final current =
        '$preview:${live.presentationId}:${live.slideIndex}:${live.followTeacher}';
    if (current == _followedPage) return;
    final first = _followedPage == null;
    _followedPage = current;
    if (live.followTeacher && (!first || live.slideIndex > 0)) {
      unawaited(_scrollToPage(live, live.slideIndex, preview: preview));
    } else if (!live.followTeacher) {
      _scrollRevision++;
    }
  }

  Widget _wideLive(LiveClass live, BoxConstraints constraints) {
    _followPage(live, preview: true);
    final presentation = live.currentPresentation;
    final slides = presentation?.slides ?? <domain.Slide>[];
    final slide = live.currentSlide;
    final question = slide == null ? null : _questionFor(live, slide);
    return Row(
      key: const ValueKey('live-wide-layout'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: constraints.maxWidth >= 1050 ? 240 : 204,
          child: ListView.builder(
            controller: _previewController,
            primary: false,
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 16),
            itemCount: slides.length + 1,
            itemBuilder: (context, item) {
              if (item == 0) {
                return Column(
                  children: [_summary(live), const Divider(height: 20)],
                );
              }
              final page = item - 1;
              return Padding(
                key: _thumbnailKeys.putIfAbsent(
                  _slideKey(live, page),
                  GlobalKey.new,
                ),
                padding: EdgeInsets.only(
                  bottom: page == slides.length - 1 ? 0 : 10,
                ),
                child: SizedBox(
                  height: 120,
                  child: SlideThumbnail(
                    key: ValueKey('live-thumbnail-$page'),
                    slide: slides[page],
                    page: page + 1,
                    questionLabel: _questionFor(live, slides[page])?.typeLabel,
                    selected: page == live.slideIndex,
                    teacherCurrent:
                        !live.ended && page == live.teacherSlideIndex,
                    onTap: () => _selectPage(live, page),
                  ),
                ),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: SlideViewport(slide)),
                if (presentation != null && slides.isNotEmpty)
                  _pageControls(live, presentation),
                if (question != null)
                  SizedBox(
                    height: (constraints.maxHeight * .38).clamp(100, 290),
                    child: SingleChildScrollView(
                      primary: false,
                      child: QuestionCard(
                        key: ValueKey(question.id),
                        controller: widget.controller,
                        classroom: live,
                        question: question,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _mobileLive(LiveClass live) {
    final presentation = live.currentPresentation;
    final slides = presentation?.slides ?? <domain.Slide>[];
    _followPage(live, preview: false);
    return NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) _scrollRevision++;
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('live-slide-feed'),
        controller: _feedController,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        itemCount: slides.length + 1,
        itemBuilder: (context, item) {
          if (item == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _summary(live),
                const Divider(height: 24),
                if (slides.isEmpty)
                  const SizedBox(
                    height: 200,
                    child: Center(child: Text('等待教师展示课件')),
                  ),
              ],
            );
          }
          final page = item - 1;
          final slide = slides[page];
          final question = _questionFor(live, slide);
          final teacherCurrent = !live.ended && page == live.teacherSlideIndex;
          final scheme = Theme.of(context).colorScheme;
          return KeyedSubtree(
            key: _slideKeys.putIfAbsent(_slideKey(live, page), GlobalKey.new),
            child: Card(
              key: ValueKey('live-slide-${slide.id}-$page'),
              margin: const EdgeInsets.only(bottom: 12),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(
                  color: teacherCurrent
                      ? scheme.primary
                      : scheme.outlineVariant,
                  width: teacherCurrent ? 3 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (teacherCurrent) ...[
                                Tooltip(
                                  message: '教师当前页',
                                  child: Icon(
                                    Icons.sensors,
                                    size: 16,
                                    color: scheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  '第 ${page + 1} 页',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: teacherCurrent
                                            ? scheme.primary
                                            : scheme.onSurfaceVariant,
                                        fontWeight: teacherCurrent
                                            ? FontWeight.w600
                                            : null,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (slide.imageUrl.isNotEmpty)
                          IconButton(
                            tooltip:
                                defaultTargetPlatform == TargetPlatform.windows
                                ? '保存图片'
                                : '保存到系统相册',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 32,
                            ),
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            onPressed: _exporting
                                ? null
                                : () => _export('image', selectedSlide: slide),
                            icon: const Icon(Icons.save_alt_rounded),
                          )
                        else
                          const SizedBox(height: 32),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: SlideImage(slide),
                  ),
                  if (question != null) ...[
                    const Divider(height: 1),
                    QuestionCard(
                      key: ValueKey(question.id),
                      controller: widget.controller,
                      classroom: live,
                      question: question,
                      embedded: true,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final live = widget.classroom, presentation = live.currentPresentation;
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
              : _mobileLive(live),
        ),
      );
    },
  );
}

class QuestionCard extends StatefulWidget {
  final AppController controller;
  final LiveClass classroom;
  final domain.Question question;
  final bool embedded;
  const QuestionCard({
    super.key,
    required this.controller,
    required this.classroom,
    required this.question,
    this.embedded = false,
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
    widget.controller.addListener(_controllerChanged);
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
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
    }
    if (oldWidget.question.id != widget.question.id ||
        !identical(oldWidget.classroom, widget.classroom)) {
      _appliedDraft = null;
      _choice.clear();
      _text.clear();
      _pics.clear();
      _error = null;
      for (final blank in _blanks) {
        blank.dispose();
      }
      _blanks.clear();
    }
    while (_blanks.length < widget.question.blankCount) {
      _blanks.add(TextEditingController());
    }
    while (_blanks.length > widget.question.blankCount) {
      _blanks.removeLast().dispose();
    }
    _readDraft();
    _choice.removeWhere((key) => !widget.question.options.containsKey(key));
    if (!_multipleOptionQuestion && _choice.length > 1) {
      final first = _choice.first;
      _choice
        ..clear()
        ..add(first);
    }
  }

  void _controllerChanged() {
    if (!mounted) return;
    setState(_readDraft);
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
    widget.controller.removeListener(_controllerChanged);
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
                    widget.controller.now().millisecondsSinceEpoch -
                    widget.question.serverOffsetMillis) /
                1000)
            .ceil()
            .clamp(0, 86400)
      : null;
  Future<void> _upload() async {
    // Store current edits before opening the image picker.
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
    final active = widget.controller.canSubmitAnswer(live, question);
    final editable = widget.controller.canEditAnswer(live, question);
    final status = widget.controller.answerStatus(live, question);
    final content = Padding(
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
            if (question.type == 3 && _multipleOptionQuestion)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('最多选择 ${question.selectionLimit} 项'),
              ),
            if (_optionQuestion && _multipleOptionQuestion)
              for (final option in question.options.entries)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: HtmlContent('${option.key}. ${option.value}'),
                  value: _choice.contains(option.key),
                  onChanged: editable && !_submitting
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
            if (_optionQuestion && !_multipleOptionQuestion)
              RadioGroup<String>(
                groupValue: _choice.firstOrNull,
                onChanged: (selected) {
                  if (!editable || _submitting) return;
                  setState(() {
                    _choice.clear();
                    if (selected != null) _choice.add(selected);
                    _error = null;
                  });
                  _draftEdited();
                },
                child: Column(
                  children: [
                    for (final option in question.options.entries)
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.trailing,
                        title: HtmlContent('${option.key}. ${option.value}'),
                        value: option.key,
                        selected: _choice.contains(option.key),
                        toggleable: true,
                        enabled: editable && !_submitting,
                      ),
                  ],
                ),
              ),
            if (!_optionQuestion && question.type == 4)
              for (var i = 0; i < _blanks.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    controller: _blanks[i],
                    enabled: editable && !_submitting,
                    decoration: InputDecoration(labelText: '第 ${i + 1} 空'),
                    onChanged: (_) => _draftEdited(),
                  ),
                ),
            if (!_optionQuestion && question.type == 5) ...[
              TextField(
                controller: _text,
                enabled: editable && !_submitting,
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
                    onPressed: !editable || _submitting
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
                  onPressed: editable && !_uploading && !_submitting
                      ? _upload
                      : null,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(_uploading ? '上传中…' : '添加图片'),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: active && !_submitting && !_uploading ? _submit : null,
              child: Text(_submitting ? '提交中…' : '提交答案'),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(status, key: ValueKey('answer-status-${question.id}')),
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
    );
    return widget.embedded ? content : Card(child: content);
  }
}
