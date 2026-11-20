import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
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
