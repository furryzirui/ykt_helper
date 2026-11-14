import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../domain/models.dart' as domain;
import '../services/app_permissions.dart';
import 'live_page.dart';
import 'permissions_page.dart';
import 'widgets.dart';

class CoursesPage extends StatelessWidget {
  final AppController controller;
  const CoursesPage({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (controller.account == null) return const ContentMessage('请在设置中登录');
      if (controller.courses.isEmpty && !controller.busy) {
        return const ContentMessage('暂无课程');
      }
      return RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: controller.courses.length,
          itemBuilder: (context, index) {
            final course = controller.courses[index];
            return Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                leading: const TintedIcon(Icons.menu_book_outlined),
                title: Text(course.name),
                subtitle: Text(
                  [
                    course.classroomName,
                    course.teacher,
                    if (course.archived) '已归档',
                  ].where((text) => text.isNotEmpty).join(' · '),
                ),
                trailing: course.liveLessonIds.isNotEmpty
                    ? const Chip(label: Text('上课中'))
                    : const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CourseLessonsPage(
                      controller: controller,
                      course: course,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
}

class CourseLessonsPage extends StatefulWidget {
  final AppController controller;
  final domain.Course course;
  const CourseLessonsPage({
    super.key,
    required this.controller,
    required this.course,
  });
  @override
  State<CourseLessonsPage> createState() => _CourseLessonsPageState();
}

class _CourseLessonsPageState extends State<CourseLessonsPage> {
  final _lessons = <domain.Lesson>[];
  final _attendance = <String, domain.AttendanceStatus>{};
  final _attendanceQueue = <({domain.Lesson lesson, int generation})>[];
  domain.Account? _account;
  int _generation = 0, _attendanceActive = 0;
  bool _accountChanged = false;
  bool _loading = false, _hasMore = true;
  String? _error;
  int _page = 0;
  @override
  void initState() {
    super.initState();
    _account = widget.controller.account;
    widget.controller.addListener(_onControllerChanged);
    _load(reset: true);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _generation++;
    _attendanceQueue.clear();
    super.dispose();
  }

  void _onControllerChanged() {
    if (identical(_account, widget.controller.account) || _accountChanged) {
      return;
    }
    setState(() {
      _accountChanged = true;
      _generation++;
      _lessons.clear();
      _attendance.clear();
      _attendanceQueue.clear();
      _loading = false;
      _error = null;
    });
  }

  bool _current(int generation) =>
      mounted &&
      !_accountChanged &&
      generation == _generation &&
      identical(_account, widget.controller.account);

  String _lessonKey(domain.Lesson lesson) =>
      '${lesson.courseId}:${lesson.classroomId}:${lesson.id}';

  void _queueAttendance(Iterable<domain.Lesson> lessons, int generation) {
    if (_account == null) return;
    for (final lesson in lessons) {
      final key = _lessonKey(lesson);
      if (_attendance.containsKey(key)) continue;
      _attendance[key] = domain.AttendanceStatus.unknown;
      // Legacy detail reports are deliberately unsupported; unknown is honest.
      if (!lesson.oldVersion) {
        _attendanceQueue.add((lesson: lesson, generation: generation));
      }
    }
    _drainAttendance();
  }

  void _drainAttendance() {
    while (mounted && _attendanceActive < 3 && _attendanceQueue.isNotEmpty) {
      final job = _attendanceQueue.removeAt(0);
      if (!_current(job.generation)) continue;
      _attendanceActive++;
      unawaited(() async {
        var status = domain.AttendanceStatus.unknown;
        try {
          status = await widget.controller.loadAttendance(job.lesson);
        } catch (_) {
          // A failed or unavailable report never proves either attendance state.
        }
        if (_current(job.generation)) {
          setState(() => _attendance[_lessonKey(job.lesson)] = status);
        }
        _attendanceActive--;
        _drainAttendance();
      }());
    }
  }

  Widget _attendanceLabel(domain.Lesson lesson) {
    final state =
        _attendance[_lessonKey(lesson)] ?? domain.AttendanceStatus.unknown;
    final scheme = Theme.of(context).colorScheme;
    final color = state == domain.AttendanceStatus.signed
        ? scheme.primary
        : state == domain.AttendanceStatus.unsigned
        ? scheme.error
        : scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          state == domain.AttendanceStatus.signed
              ? Icons.check_circle_outline_rounded
              : state == domain.AttendanceStatus.unsigned
              ? Icons.radio_button_unchecked_rounded
              : Icons.help_outline_rounded,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(
          state == domain.AttendanceStatus.signed
              ? '已签到'
              : state == domain.AttendanceStatus.unsigned
              ? '未签到'
              : '未同步',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || _accountChanged) return;
    if (reset) {
      _generation++;
      _attendance.clear();
      _attendanceQueue.clear();
    }
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = reset ? 0 : _page;
      final result = await widget.controller.loadLessons(widget.course, page);
      if (!_current(generation)) return;
      setState(() {
        if (reset) _lessons.clear();
        for (final lesson in result.lessons) {
          if (!_lessons.any((item) => item.id == lesson.id)) {
            _lessons.add(lesson);
          }
        }
        _page = page + 1;
        _hasMore = result.hasMore;
        _queueAttendance(_lessons, generation);
      });
    } catch (error) {
      if (_current(generation)) setState(() => _error = error.toString());
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: fullTitleAppBar(context, title: widget.course.name),
    body: _accountChanged
        ? const ContentMessage('账号已变更，请返回课程列表')
        : RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (widget.course.classroomName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 2, top: 4, bottom: 12),
                    child: Text(
                      widget.course.classroomName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final lesson in _lessons)
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      leading: const TintedIcon(Icons.class_outlined),
                      title: Text(lesson.title),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (lesson.startedAt > 0)
                              Text(formatTime(lesson.startedAt)),
                            _attendanceLabel(lesson),
                          ],
                        ),
                      ),
                      trailing: lesson.oldVersion
                          ? const Chip(label: Text('旧版课堂'))
                          : lesson.live
                          ? const Chip(label: Text('上课中'))
                          : const Icon(Icons.chevron_right),
                      onTap: () {
                        if (lesson.oldVersion) {
                          showDialog<void>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              title: const Text('旧版课堂'),
                              content: const Text('此旧版课堂暂不支持查看详情，请使用官方客户端查看。'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(),
                                  child: const Text('知道了'),
                                ),
                              ],
                            ),
                          );
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => LessonDetailPage(
                              controller: widget.controller,
                              lesson: lesson,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_error != null)
                  ContentMessage(_error!, retry: () => _load()),
                if (!_loading && _error == null && _lessons.isEmpty)
                  const ContentMessage('暂无课堂'),
                if (!_loading &&
                    _error == null &&
                    _hasMore &&
                    _lessons.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      onPressed: _load,
                      child: const Text('加载更多课堂'),
                    ),
                  ),
              ],
            ),
          ),
  );
}

class LessonDetailPage extends StatefulWidget {
  final AppController controller;
  final domain.Lesson lesson;
  const LessonDetailPage({
    super.key,
    required this.controller,
    required this.lesson,
  });
  @override
  State<LessonDetailPage> createState() => _LessonDetailPageState();
}

class _LessonDetailPageState extends State<LessonDetailPage> {
  late Future<domain.LessonDetail> _detail;
  bool _entering = false, _downloading = false;

  @override
  void initState() {
    super.initState();
    _detail = widget.controller.loadDetail(widget.lesson);
  }

  Future<void> _reload() async {
    final next = widget.controller.loadDetail(widget.lesson);
    setState(() => _detail = next);
    try {
      await next;
    } catch (_) {
      // The FutureBuilder displays the error and its retry action.
    }
  }

  Future<void> _download(
    domain.LessonDetail detail,
    String format, {
    domain.Slide? slide,
  }) async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      if (slide != null || format == 'album') {
        if (!await ensureAppPermission(context, AppPermission.photos) ||
            !mounted) {
          return;
        }
      }
      if (slide != null) {
        await widget.controller.saveSlide(slide);
        if (mounted) _message('已保存到系统相册');
      } else if (format == 'album') {
        final count = await widget.controller.saveSlidesToGallery(
          detail.reviewSlides,
        );
        if (mounted) _message('已保存 $count 张图片到系统相册');
      } else {
        final slides = detail.reviewSlides
            .where((slide) => slide.imageUrl.isNotEmpty)
            .indexed
            .map(
              (entry) => domain.Slide(
                id: entry.$2.id,
                index: entry.$1,
                imageUrl: entry.$2.imageUrl,
                text: entry.$2.text,
                question: entry.$2.question,
                ownAnswer: entry.$2.ownAnswer,
              ),
            )
            .toList();
        if (slides.isEmpty) {
          throw const domain.ApiFailure('课堂回顾没有可下载的图片');
        }
        await widget.controller.exportSlides(
          domain.Presentation(
            id: detail.lesson.id,
            title: detail.lesson.title,
            slides: slides,
          ),
          pptx: format == 'pptx',
        );
      }
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _enter() async {
    setState(() => _entering = true);
    try {
      final live = await widget.controller.enter(widget.lesson);
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                LivePage(controller: widget.controller, classroom: live),
          ),
        );
      }
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _entering = false);
    }
  }

  Widget _summary(domain.LessonDetail detail) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (detail.teacher.isNotEmpty) ...[
            StatusLine(icon: Icons.person_outline, text: detail.teacher),
            const SizedBox(height: 10),
          ],
          if (detail.lesson.startedAt > 0) ...[
            StatusLine(
              icon: Icons.schedule,
              text: '开始 ${formatTime(detail.lesson.startedAt)}',
            ),
            const SizedBox(height: 8),
          ],
          if (detail.lesson.endedAt > 0) ...[
            StatusLine(
              icon: Icons.event_available_outlined,
              text: '结束 ${formatTime(detail.lesson.endedAt)}',
            ),
            const SizedBox(height: 8),
          ],
          StatusLine(icon: Icons.how_to_reg_outlined, text: detail.checkinText),
          for (final warning in detail.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                warning,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (widget.lesson.live) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _entering ? null : _enter,
              icon: const Icon(Icons.login, size: 18),
              label: Text(_entering ? '进入中…' : '签到并进入课堂'),
            ),
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<domain.LessonDetail>(
    future: _detail,
    builder: (context, snapshot) {
      final detail = snapshot.data;
      final available =
          snapshot.connectionState == ConnectionState.done &&
          !snapshot.hasError &&
          detail != null &&
          !detail.lesson.oldVersion;
      final hasImages =
          available &&
          detail.reviewSlides.any((slide) => slide.imageUrl.isNotEmpty);
      return Scaffold(
        appBar: fullTitleAppBar(
          context,
          title: widget.lesson.title,
          actions: [
            if (_downloading)
              const SizedBox(
                width: 48,
                child: Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              PopupMenuButton<String>(
                tooltip: '下载课件',
                enabled: hasImages,
                icon: const Icon(Icons.download_outlined),
                onSelected: (format) => _download(detail!, format),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'album', child: Text('全部保存到系统相册')),
                  PopupMenuItem(value: 'zip', child: Text('导出全部图片 ZIP')),
                  PopupMenuItem(value: 'pptx', child: Text('导出完整 PPTX')),
                ],
              ),
          ],
        ),
        body: snapshot.hasError
            ? ContentMessage(snapshot.error.toString(), retry: _reload)
            : detail == null
            ? const Center(child: CircularProgressIndicator())
            : detail.lesson.oldVersion
            ? const ContentMessage('此旧版课堂暂不支持查看详情，请使用官方客户端查看。')
            : RefreshIndicator(
                onRefresh: _reload,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _summary(detail),
                            const Divider(height: 24),
                            if (!detail.answersKnown)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  detail.answerError ?? '作答状态未同步，已有答案可能未显示',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (detail.reviewSlides.isEmpty)
                      const SliverToBoxAdapter(child: ContentMessage('暂无课堂回顾'))
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        sliver: SliverList.builder(
                          itemCount: detail.reviewSlides.length,
                          itemBuilder: (context, index) {
                            final slide = detail.reviewSlides[index];
                            return ReviewSlideCard(
                              key: ValueKey('review-${slide.id}-$index'),
                              slide: slide,
                              page: index + 1,
                              record:
                                  slide.ownAnswer ??
                                  detail.answers[slide.question?.id],
                              onSave: _downloading
                                  ? null
                                  : () => _download(
                                      detail,
                                      'image',
                                      slide: slide,
                                    ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
      );
    },
  );
}

class ReviewSlideCard extends StatelessWidget {
  final domain.Slide slide;
  final int page;
  final domain.AnswerRecord? record;
  final VoidCallback? onSave;
  const ReviewSlideCard({
    super.key,
    required this.slide,
    required this.page,
    this.record,
    this.onSave,
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '第 $page 页',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (slide.imageUrl.isNotEmpty)
                IconButton(
                  tooltip: '保存到系统相册',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onPressed: onSave,
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
        if (slide.question != null || record != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (slide.question != null) ...[
                  HtmlContent(slide.question!.body),
                  for (final option in slide.question!.options.entries)
                    HtmlContent('${option.key}. ${option.value}'),
                ],
                if (record != null) OwnAnswer(record!),
              ],
            ),
          ),
      ],
    ),
  );
}
