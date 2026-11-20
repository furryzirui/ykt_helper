import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/ai_answer.dart';
import 'package:ykt_helper/services/background_runtime.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/course_pages.dart';
import 'package:ykt_helper/ui/live_page.dart';
import 'package:ykt_helper/ui/widgets.dart';

const _course = Course(courseId: 'course', classroomId: 'room', name: '课程列表入口');
const _lesson = Lesson(
  id: 'live',
  courseId: 'course',
  classroomId: 'room',
  title: '本次实时课堂',
  live: true,
);
const _first = Question(
  id: 'q-first',
  type: 5,
  body: '第一页题目',
  dt: 1,
  limit: -1,
);
const _later = Question(
  id: 'q-later',
  type: 5,
  body: '后续页面题目',
  dt: 1,
  limit: -1,
);

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Autostart extends AppAutostart {
  @override
  bool get supported => false;
  @override
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {}
  @override
  Future<void> setSuspended(bool suspended) async {}
}

class _Background extends BackgroundRuntime {
  @override
  bool get supported => false;
  @override
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {}
  @override
  Future<bool> setEnabled(bool enabled) async => true;
}

class _EmptyApi extends RainApi {
  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<List<Lesson>> liveLessons() async => [];
}

class _DelayedAi extends AiAnswerService {
  int requests = 0;
  final response = Completer<String>();
  @override
  Future<String> generate({
    required AppSettings settings,
    required Question question,
    required List<Slide> slides,
    required Future<Uint8List> Function(String url) loadImage,
  }) {
    requests++;
    return response.future;
  }
}

class _Controller extends AppController {
  int enters = 0, details = 0;
  bool listedLive = true;
  Completer<LessonDetail>? pendingDetail;
  _Controller()
    : super(store: _Store(), startTimers: false, connectSockets: false) {
    initialized = true;
    account = const Account(id: 'user', name: '用户');
    courses = [_course];
    liveLessons = [_lesson];
  }
  @override
  Future<LessonPage> loadLessons(Course course, int page) async => LessonPage([
    listedLive
        ? _lesson
        : const Lesson(
            id: 'live',
            courseId: 'course',
            classroomId: 'room',
            title: '本次实时课堂',
          ),
  ], false);
  @override
  Future<AttendanceStatus> loadAttendance(Lesson lesson) async =>
      AttendanceStatus.signed;
  @override
  Future<LessonDetail> loadDetail(Lesson lesson) async {
    details++;
    if (pendingDetail != null) return pendingDetail!.future;
    return const LessonDetail(lesson: _lesson);
  }

  @override
  Future<LiveClass> enter(Lesson lesson, {bool automatic = false}) async {
    enters++;
    final live = classrooms[lesson.id] ?? _live();
    classrooms[lesson.id] = live;
    return live;
  }

  void pulse() => notifyListeners();
}

LiveClass _live({int pages = 3}) =>
    LiveClass(
        lesson: _lesson,
        session: const ClassroomSession(
          userId: 'user',
          lessonId: 'live',
          bearer: 'test',
          lessonToken: 'test',
        ),
      )
      ..presentationId = 'deck'
      ..presentations['deck'] = Presentation(
        id: 'deck',
        title: '课件',
        slides: [
          for (var i = 0; i < pages; i++)
            Slide(
              id: 's$i',
              index: i,
              imageUrl: '',
              question: i == 0
                  ? _first
                  : i == pages - 1
                  ? _later
                  : null,
            ),
        ],
      )
      ..questions.addAll({
        'q-first': _first,
        'q-later': _later,
        'orphan': const Question(id: 'orphan', type: 5, body: '不属于本课件的题目'),
      })
      ..answersKnown = true
      ..activeProblemIds.addAll(['q-first', 'q-later']);

Future<void> _mount(WidgetTester tester, Widget child, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(theme: rainTheme(Brightness.light), home: child),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('竖屏逐页显示PPT及该页题卡，不重复列出全部题目', (tester) async {
    final controller = _Controller(), live = _live();
    controller.classrooms[live.lesson.id] = live;
    await _mount(
      tester,
      LivePage(controller: controller, classroom: live),
      const Size(390, 840),
    );
    final firstPage = find.byKey(const ValueKey('live-slide-s0-0'));
    expect(
      find.descendant(of: firstPage, matching: find.byType(SlideImage)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: firstPage,
        matching: find.byKey(const ValueKey('q-first')),
      ),
      findsOneWidget,
    );
    expect(find.text('课堂题目'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.text('不属于本课件的题目'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('live-slide-s2-2')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-slide-s2-2')),
        matching: find.byKey(const ValueKey('q-later')),
      ),
      findsOneWidget,
    );
    expect(live.followTeacher, isTrue, reason: '手动浏览不关闭教师跟随');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('横屏与回顾同侧栏布局，只有选中PPT下显示该题', (tester) async {
    final controller = _Controller(), live = _live();
    controller.classrooms[live.lesson.id] = live;
    await _mount(
      tester,
      LivePage(controller: controller, classroom: live),
      const Size(1280, 800),
    );
    final slideRect = tester.getRect(find.byType(SlideViewport));
    final cardRect = tester.getRect(find.byType(QuestionCard));
    expect(find.byTooltip('刷新课堂'), findsOneWidget);
    expect(find.byTooltip('导出课件'), findsOneWidget);
    expect(find.byTooltip('同步我的答案'), findsNothing);
    expect(cardRect.top, greaterThan(slideRect.bottom));
    expect(find.text('后续页面题目'), findsNothing);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionCard), findsNothing);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionCard), findsOneWidget);
    expect(find.text('第一页题目'), findsNothing);
    expect(find.text('后续页面题目'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final size in [const Size(390, 840), const Size(1280, 800)]) {
    testWidgets('教师真实页独立于浏览页和跟随开关 $size', (tester) async {
      final controller = _Controller(),
          live = _live(pages: 4)
            ..teacherSlideIndex = 2
            ..slideIndex = 0
            ..followTeacher = false;
      controller.classrooms[live.lesson.id] = live;
      await _mount(
        tester,
        LivePage(controller: controller, classroom: live),
        size,
      );
      final mobile = size.width < 800;
      final current = find.byKey(
        ValueKey(mobile ? 'live-slide-s2-2' : 'live-thumbnail-2'),
      );
      if (mobile) {
        await tester.scrollUntilVisible(
          current,
          240,
          scrollable: find.byType(Scrollable).first,
        );
      }
      expect(
        find.descendant(of: current, matching: find.byTooltip('教师当前页')),
        findsOneWidget,
      );
      if (mobile) {
        final card = tester.widget<Card>(current);
        expect((card.shape! as RoundedRectangleBorder).side.width, 3);
        expect(
          (card.shape! as RoundedRectangleBorder).side.color,
          rainTheme(Brightness.light).colorScheme.primary,
        );
      } else {
        expect(tester.widget<SlideThumbnail>(current).selected, isFalse);
        expect(
          tester
              .widget<SlideThumbnail>(
                find.byKey(const ValueKey('live-thumbnail-0')),
              )
              .selected,
          isTrue,
        );
      }
      await controller.processEvent(live, {
        'op': 'slidenav',
        'slide': {'si': 2},
      });
      await tester.pumpAndSettle();
      final next = find.byKey(
        ValueKey(mobile ? 'live-slide-s1-1' : 'live-thumbnail-1'),
      );
      expect(
        find.descendant(of: current, matching: find.byTooltip('教师当前页')),
        findsNothing,
      );
      expect(
        find.descendant(of: next, matching: find.byTooltip('教师当前页')),
        findsOneWidget,
      );
      expect(live.slideIndex, 0);
      expect(live.followTeacher, isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('手机PPT题卡共用一个边框，放大图片不绘制到题卡区域', (tester) async {
    final imageData = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xffff00ff), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(320, 180);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return bytes!.buffer.asUint8List();
    });
    final imageProvider = MemoryImage(imageData!);
    const url = 'https://offline.invalid/card-boundary.png';
    final cached = await tester.runAsync(() async {
      final completer = Completer<ImageInfo>();
      ui.decodeImageFromList(
        imageData,
        (image) => completer.complete(ImageInfo(image: image)),
      );
      return completer.future;
    });
    PaintingBinding.instance.imageCache.putIfAbsent(
      const NetworkImage(url),
      () => OneFrameImageStreamCompleter(Future.value(cached!)),
    );
    final controller = _Controller(), live = _live();
    live.presentations['deck'] = const Presentation(
      id: 'deck',
      title: '课件',
      slides: [Slide(id: 'colored', index: 0, imageUrl: url, question: _first)],
    );
    controller.classrooms[live.lesson.id] = live;
    const boundaryKey = ValueKey('slide-card-render');
    await _mount(
      tester,
      RepaintBoundary(
        key: boundaryKey,
        child: LivePage(controller: controller, classroom: live),
      ),
      const Size(390, 840),
    );
    // Resolve the generated bytes through a real memory image as well as the
    // live page's pre-cached NetworkImage, without fetching the network.
    await tester.runAsync(
      () =>
          precacheImage(imageProvider, tester.element(find.byType(SlideImage))),
    );
    await tester.ensureVisible(find.byType(SlideImage));
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('live-slide-colored-0'));
    final question = find.descendant(
      of: page,
      matching: find.byType(QuestionCard),
    );
    expect(tester.widget<QuestionCard>(question).embedded, isTrue);
    expect(
      find.descendant(of: page, matching: find.byType(Card)),
      findsNothing,
    );
    expect(tester.widget<Card>(page).clipBehavior, Clip.antiAlias);
    final slideRect = tester.getRect(find.byType(SlideImage));
    final questionRect = tester.getRect(question);
    expect(questionRect.top, greaterThanOrEqualTo(slideRect.bottom));
    final viewer = find.descendant(
      of: page,
      matching: find.byType(InteractiveViewer),
    );
    final focal = tester.getCenter(find.byType(SlideImage));
    final first = await tester.startGesture(
      focal - const Offset(24, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      focal + const Offset(24, 0),
      pointer: 2,
    );
    await second.moveTo(focal + const Offset(100, 0));
    await first.moveTo(focal - const Offset(100, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final top = boundary
          .globalToLocal(Offset(questionRect.center.dx, questionRect.top + 12))
          .dy
          .toInt();
      for (var y = top; y < (top + 40).clamp(0, image.height); y++) {
        for (var x = 30; x < image.width - 30; x++) {
          final offset = (y * image.width + x) * 4;
          expect(
            pixels!.getUint8(offset) == 255 &&
                pixels.getUint8(offset + 1) == 0 &&
                pixels.getUint8(offset + 2) == 255,
            isFalse,
            reason: '放大后的图片不能覆盖题卡像素',
          );
        }
      }
      final folder = Directory('.workspace-bootstrap/qa-1.1.1')
        ..createSync(recursive: true);
      File(
        '${folder.path}/mobile-slide-question-zoom.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
      image.dispose();
    });
    expect(
      tester.widget<InteractiveViewer>(viewer).clipBehavior,
      Clip.hardEdge,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final pages in [8, 30]) {
    testWidgets('$pages页课件跟随时中段置顶、尾段自然到底，手动浏览和关闭跟随不受影响', (tester) async {
      final controller = _Controller(), live = _live(pages: pages);
      controller.classrooms[live.lesson.id] = live;
      await _mount(
        tester,
        LivePage(controller: controller, classroom: live),
        const Size(1280, 800),
      );
      final list = find.byType(ListView).first;
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final state = tester.state<ScrollableState>(scrollable);
      final pane = tester.getRect(scrollable);
      final middlePage = pages == 8 ? 2 : 8;
      final tailPage = pages == 8 ? 7 : 28;

      await controller.processEvent(live, {
        'op': 'slidenav',
        'slide': {'si': middlePage},
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(find.byKey(ValueKey('live-thumbnail-${middlePage - 1}')))
            .top,
        closeTo(pane.top, 1),
      );

      await controller.processEvent(live, {
        'op': 'slidenav',
        'slide': {'si': tailPage},
      });
      await tester.pumpAndSettle();
      final selected = find.byKey(ValueKey('live-thumbnail-${tailPage - 1}'));
      final last = find.byKey(ValueKey('live-thumbnail-${pages - 1}'));
      expect(selected, findsOneWidget);
      expect(tester.getRect(selected).top, greaterThan(pane.top));
      expect(tester.getRect(selected).bottom, lessThan(pane.bottom));
      expect(state.position.pixels, closeTo(state.position.maxScrollExtent, 1));
      expect(
        tester.getRect(last).bottom,
        closeTo(pane.bottom - 16, 1),
        reason: '尾页只保留常规16像素边距，不填充大片空白',
      );

      await tester.drag(list, const Offset(0, 260));
      await tester.pumpAndSettle();
      final manualOffset = state.position.pixels;
      expect(live.followTeacher, isTrue);
      controller.pulse();
      await tester.pumpAndSettle();
      expect(state.position.pixels, manualOffset, reason: '普通刷新不拉回选中页');
      controller.followTeacher(live, false);
      await controller.processEvent(live, {
        'op': 'slidenav',
        'slide': {'si': middlePage},
      });
      await tester.pumpAndSettle();
      expect(state.position.pixels, manualOffset);
      controller.followTeacher(live, true);
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(find.byKey(ValueKey('live-thumbnail-${middlePage - 1}')))
            .top,
        closeTo(pane.top, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('同一题卡实例中途启用固定答题立即显示生成选项并保留人工修改', (tester) async {
    final controller =
        AppController(
            api: _EmptyApi(),
            store: _Store(),
            background: _Background(),
            autostart: _Autostart(),
            startTimers: false,
            connectSockets: false,
          )
          ..initialized = true
          ..account = const Account(id: 'user', name: '用户');
    final live = _live();
    const question = Question(
      id: 'prepared-choice',
      type: 1,
      body: '准备中的选择题',
      options: {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'},
    );
    live.questions
      ..clear()
      ..[question.id] = question;
    live.presentations['deck'] = const Presentation(
      id: 'deck',
      title: '课件',
      slides: [
        Slide(id: 'q-slide', index: 0, imageUrl: '', question: question),
      ],
    );
    live.activeProblemIds.clear();
    controller.classrooms[live.lesson.id] = live;
    final card = QuestionCard(
      controller: controller,
      classroom: live,
      question: question,
    );
    await _mount(
      tester,
      Scaffold(body: SingleChildScrollView(child: card)),
      const Size(390, 840),
    );
    final initialState = tester.state(find.byType(QuestionCard));
    expect(
      tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .every((tile) => tile.value == false),
      isTrue,
    );
    await controller.saveSettings(
      AppSettings(autoAnswer: true, fixedSingleAnswer: 'C'),
    );
    await tester.pump();
    expect(tester.state(find.byType(QuestionCard)), same(initialState));
    expect(live.draftAnswers[question.id], ['C']);
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(2))
          .value,
      isTrue,
    );
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await controller.saveSettings(
      AppSettings(autoAnswer: true, fixedSingleAnswer: 'D'),
    );
    await tester.pump();
    expect(live.draftAnswers[question.id], ['A']);
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(3))
          .value,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final rebuildParent in [false, true]) {
    testWidgets('异步自定义AI完成后同一题卡即时显示选项，父监听=$rebuildParent', (tester) async {
      final ai = _DelayedAi();
      final controller =
          AppController(
              api: _EmptyApi(),
              ai: ai,
              store: _Store(),
              background: _Background(),
              autostart: _Autostart(),
              startTimers: false,
              connectSockets: false,
            )
            ..initialized = true
            ..account = const Account(id: 'user', name: '用户');
      final live = _live();
      const question = Question(
        id: 'ai-choice',
        type: 1,
        body: '自定义AI选择题',
        options: {'A': '甲', 'B': '乙', 'C': '丙', 'D': '丁'},
      );
      live.questions
        ..clear()
        ..[question.id] = question;
      live.presentations['deck'] = const Presentation(
        id: 'deck',
        title: '课件',
        slides: [
          Slide(id: 'ai-slide', index: 0, imageUrl: '', question: question),
        ],
      );
      live.activeProblemIds.clear();
      controller.classrooms[live.lesson.id] = live;
      final fixedCard = QuestionCard(
        key: const ValueKey('same-ai-card'),
        controller: controller,
        classroom: live,
        question: question,
      );
      final child = rebuildParent
          ? AnimatedBuilder(
              animation: controller,
              builder: (context, _) => QuestionCard(
                key: const ValueKey('same-ai-card'),
                controller: controller,
                classroom: live,
                question: question,
              ),
            )
          : fixedCard;
      await _mount(
        tester,
        Scaffold(body: SingleChildScrollView(child: child)),
        const Size(390, 840),
      );
      final state = tester.state(find.byType(QuestionCard));
      await controller.saveSettings(
        AppSettings(
          autoAnswer: true,
          answerMode: AnswerMode.ai,
          baseUrl: 'https://offline.invalid/v1',
          apiKey: 'test-key',
          model: 'test-model',
        ),
      );
      await tester.pump();
      expect(ai.requests, 1);
      expect(live.draftAnswers.containsKey(question.id), isFalse);
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((tile) => tile.value == false),
        isTrue,
      );
      ai.response.complete('C');
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(QuestionCard)), same(state));
      expect(live.draftAnswers[question.id], ['C']);
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(2))
            .value,
        isTrue,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
        reason: '尚未发布的题只能预填',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: '父级notify重建与题卡自身监听不得在build期间setState报错',
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('预生成答案允许编辑但不能提交，结束和提交状态覆盖旧填充文案', (tester) async {
    final controller = _Controller(), live = _live();
    controller.classrooms[live.lesson.id] = live;
    const question = Question(id: 'pending', body: '尚未发布的题目', type: 5);
    live.questions[question.id] = question;
    live.draftAnswers[question.id] = {
      'content': '预生成回答',
      'pics': [],
      'videos': [],
    };
    live.autoStates[question.id] = '答案已填充，待确认提交';
    await _mount(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => QuestionCard(
              controller: controller,
              classroom: live,
              question: live.questions[question.id]!,
            ),
          ),
        ),
      ),
      const Size(390, 840),
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('答案已填充，等待开始作答'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '发布前手动修改');
    await tester.pump();
    expect(live.draftAnswers[question.id]['content'], '发布前手动修改');
    live.closedAtSequence[question.id] = 1;
    controller.pulse();
    await tester.pump();
    expect(find.text('作答已结束'), findsOneWidget);
    expect(find.text('答案已填充，待确认提交'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    live.answers[question.id] = const AnswerRecord(
      problemId: 'pending',
      answer: {'content': '已确认的回答'},
      source: AnswerSource.server,
    );
    controller.pulse();
    await tester.pump();
    expect(find.text('答案已提交'), findsOneWidget);
    expect(find.text('作答已结束'), findsNothing);
    expect(find.text('答案已填充，待确认提交'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('旧账号详情迟到返回上课状态不为新账号进入课堂', (tester) async {
    final pending = Completer<LessonDetail>();
    final controller = _Controller()..pendingDetail = pending;
    await tester.pumpWidget(
      MaterialApp(
        home: LessonDetailPage(
          controller: controller,
          lesson: const Lesson(
            id: 'live',
            courseId: 'course',
            classroomId: 'room',
            title: '原账号课堂',
          ),
        ),
      ),
    );
    await tester.pump();
    controller.account = const Account(id: 'other', name: '另一个用户');
    pending.complete(const LessonDetail(lesson: _lesson));
    controller.pulse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.enters, 0);
    expect(find.byType(LivePage), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final listedLive in [true, false]) {
    testWidgets('课程入口${listedLive ? '已知上课中' : '详情返回上课中'}跳转动态，返回保持动态tab', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _Controller()..listedLive = listedLive;
      await tester.pumpWidget(
        RainApp(controller: controller, startupChecks: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('课程列表入口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次实时课堂'));
      await tester.pumpAndSettle();
      expect(find.byType(LivePage), findsOneWidget);
      expect(controller.enters, 1);
      expect(controller.details, listedLive ? 0 : 1);
      expect(find.text('lesson_on'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      expect(find.byType(CourseLessonsPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
