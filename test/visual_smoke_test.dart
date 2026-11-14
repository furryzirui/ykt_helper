// Offline layout checks only. None of these fixtures are included in the app.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/background_runtime.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/automation_page.dart';
import 'package:ykt_helper/ui/course_pages.dart';
import 'package:ykt_helper/ui/live_page.dart';

const _screenshots = bool.fromEnvironment('GENERATE_SCREENSHOTS');
final _boundary = GlobalKey();
const _slideUrl = 'https://offline.invalid/layout-slide.png';

Future<void> _cacheSlide(WidgetTester tester) async {
  final image = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 640, 8),
      Paint()..color = const Color(0xff287b83),
    );
    void text(String value, Offset offset, double size, Color color) {
      final painter = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(fontFamily: 'Roboto', fontSize: size, color: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 560);
      painter.paint(canvas, offset);
      painter.dispose();
    }

    text('第一章  导数与微分', const Offset(32, 32), 18, const Color(0xff647985));
    text('导数的几何意义', const Offset(32, 82), 30, const Color(0xff1f3442));
    text('请简述导数的几何意义。', const Offset(32, 150), 22, const Color(0xff1f3442));
    text(
      'f′(x) = lim [ f(x + h) − f(x) ] / h',
      const Offset(32, 208),
      22,
      const Color(0xff287b83),
    );
    text('微积分基础', const Offset(32, 320), 14, const Color(0xff647985));
    final picture = recorder.endRecording();
    final result = await picture.toImage(640, 360);
    picture.dispose();
    return result;
  });
  PaintingBinding.instance.imageCache.putIfAbsent(
    const NetworkImage(_slideUrl),
    () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
  );
  await tester.pump();
}

class _MemoryStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _NoBackground extends BackgroundRuntime {
  @override
  bool get enabled => true;
  @override
  Future<bool> setEnabled(bool enabled) async => true;
}

class _VisualController extends AppController {
  @override
  Future<AttendanceStatus> loadAttendance(Lesson lesson) async =>
      lesson.id.endsWith('0')
      ? AttendanceStatus.signed
      : AttendanceStatus.unsigned;
  LessonDetail? detailResult;
  _VisualController()
    : super(
        store: _MemoryStore(),
        background: _NoBackground(),
        startTimers: false,
        connectSockets: false,
      ) {
    initialized = true;
    account = const Account(id: 'qa-user', name: '测试学生', school: '离线视觉验收');
    courses = const [
      Course(
        courseId: 'math',
        classroomId: 'class-a',
        name: '高等数学（上）2026 秋季第一教学班 · 微积分与综合应用',
        classroomName: '2026 秋季 · 教学一班',
        teacher: '教师甲',
        liveLessonIds: ['live'],
      ),
      Course(
        courseId: 'math',
        classroomId: 'class-b',
        name: '高等数学',
        classroomName: '2026 秋季 · 教学二班',
        teacher: '教师乙',
      ),
      Course(
        courseId: 'history',
        classroomId: 'class-c',
        name: '中国近现代史纲要',
        classroomName: '2025 春季 · 通识课程第三教学班',
        teacher: '教师丙',
        archived: true,
      ),
    ];
  }
  @override
  Future<LessonPage> loadLessons(Course course, int page) async => LessonPage([
    for (var i = 0; i < 5; i++)
      Lesson(
        id: 'lesson-$page-$i',
        courseId: course.courseId,
        classroomId: course.classroomId,
        title: '第 ${page * 5 + i + 1} 次课堂 · 微积分基础',
        startedAt: DateTime(2026, 11, 13 - i, 10, 0).millisecondsSinceEpoch,
        live: page == 0 && i == 0,
      ),
  ], page == 0);
  @override
  Future<LessonDetail> loadDetail(Lesson lesson) => detailResult == null
      ? super.loadDetail(lesson)
      : Future.value(detailResult!);
}

Widget _page(Widget child, {String? title}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: rainTheme(Brightness.light),
  home: title == null
      ? child
      : Scaffold(
          appBar: AppBar(title: Text(title)),
          body: child,
        ),
);

Future<void> _capture(WidgetTester tester, String name) async {
  expect(
    tester.takeException(),
    isNull,
    reason: '$name must have no layout errors',
  );
  if (!_screenshots) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('.workspace-bootstrap/qa');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _mount(WidgetTester tester, Widget child, double scale) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(RepaintBoundary(key: _boundary, child: child));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Normal tests use the same Ahem font on every host. Only optional screenshots
    // load a local Chinese font; it is neither copied nor bundled in the app.
    final font = File(
      '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyh.ttc',
    );
    if (_screenshots && await font.exists()) {
      final bytes = ByteData.sublistView(await font.readAsBytes());
      await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
    }
    final config = File('.dart_tool/package_config.json');
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final flutter = packages.cast<Map>().firstWhere(
      (package) => package['name'] == 'flutter',
    );
    final flutterRoot = Directory.fromUri(
      config.absolute.uri.resolve(flutter['rootUri'] as String),
    ).uri;
    final icons = File.fromUri(
      flutterRoot.resolve(
        '../../bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      ),
    );
    if (await icons.exists()) {
      final bytes = ByteData.sublistView(await icons.readAsBytes());
      await (FontLoader('MaterialIcons')..addFont(Future.value(bytes))).load();
    }
  });
  for (final scale in [1.0, 1.5]) {
    final suffix = scale == 1 ? 'normal' : 'large-text';
    testWidgets('360x800 courses and history $suffix', (tester) async {
      final controller = _VisualController();
      await _mount(
        tester,
        RainApp(controller: controller, startupChecks: false),
        scale,
      );
      await _capture(tester, 'courses-$suffix');
      expect(find.text('高等数学'), findsOneWidget);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: _page(
            CourseLessonsPage(
              controller: controller,
              course: controller.courses.first,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(tester, 'classrooms-$suffix');
      final loadMore = find.widgetWithText(OutlinedButton, '加载更多课堂');
      await tester.scrollUntilVisible(
        loadMore,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      // ensureVisible changes the scroll offset; render its new position before
      // hit testing, including when the element was built in the cache area.
      await tester.pumpAndSettle();
      expect(loadMore.hitTestable(), findsOneWidget);
      await tester.tap(loadMore);
      await tester.pumpAndSettle();
      expect(find.text('第 6 次课堂 · 微积分基础'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('360x800 live question and own answer $suffix', (tester) async {
      final controller = _VisualController();
      final live = LiveClass(
        lesson: const Lesson(
          id: 'live',
          courseId: 'math',
          classroomId: 'class-a',
          title: '高等数学第一教学班 · 第十二次课堂：微分中值定理及其综合应用',
          live: true,
        ),
        session: const ClassroomSession(
          userId: 'qa-user',
          lessonId: 'live',
          bearer: 'fixture',
          lessonToken: 'fixture',
        ),
      );
      const question = Question(
        id: 'question',
        body: '<p>函数 f(x) = x² 在 x = 2 处的导数是多少？</p>',
        type: 1,
        options: {'A': '2', 'B': '4', 'C': '6', 'D': '8'},
      );
      live.connectionLabel = '实时连接正常';
      live.answersKnown = true;
      live.presentationId = 'presentation';
      live.presentations['presentation'] = const Presentation(
        id: 'presentation',
        title: '第一章 · 导数与微分',
        slides: [
          Slide(id: 'slide', index: 0, imageUrl: '', question: question),
        ],
      );
      live.questions[question.id] = question;
      live.answers[question.id] = const AnswerRecord(
        problemId: 'question',
        answer: ['B'],
        source: AnswerSource.server,
        score: 0,
      );
      await _mount(
        tester,
        _page(LivePage(controller: controller, classroom: live)),
        scale,
      );
      await _capture(tester, 'live-$suffix');
      await tester.scrollUntilVisible(
        find.text('我的答案 · 已提交').first,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await _capture(tester, 'own-answer-$suffix');
      expect(find.text('得分：0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('360x800 history detail and review $suffix', (tester) async {
      final controller = _VisualController();
      await _cacheSlide(tester);
      const question = Question(
        id: 'review-question',
        body: '<p>请简述导数的几何意义。</p>',
        type: 5,
      );
      final detail = LessonDetail(
        lesson: Lesson(
          id: 'past',
          courseId: 'math',
          classroomId: 'class-a',
          title: '高等数学第一教学班 · 第十一次课堂：导数的几何意义及其应用',
          startedAt: DateTime(2026, 11, 12, 10).millisecondsSinceEpoch,
          endedAt: DateTime(2026, 11, 12, 11, 30).millisecondsSinceEpoch,
        ),
        teacher: '教师甲',
        checkinText: '已签到',
        answersKnown: true,
        reviewSlides: const [
          Slide(
            id: 'review-slide',
            index: 0,
            imageUrl: _slideUrl,
            question: question,
          ),
        ],
        answers: const {
          'review-question': AnswerRecord(
            problemId: 'review-question',
            answer: {'content': '曲线在该点切线的斜率。'},
            source: AnswerSource.server,
            score: -1,
          ),
        },
      );
      controller.detailResult = detail;
      await _mount(
        tester,
        _page(LessonDetailPage(controller: controller, lesson: detail.lesson)),
        scale,
      );
      await _capture(tester, 'history-detail-$suffix');
      expect(find.text('课件'), findsNothing);
      expect(find.text('回放'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('待批改'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await _capture(tester, 'review-$suffix');
      expect(find.text('课堂回顾'), findsNothing);
      expect(find.text('待批改'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('360x800 AI settings four slide scopes $suffix', (
      tester,
    ) async {
      final controller = _VisualController();
      controller.settings = AppSettings(
        autoEnter: true,
        autoAnswer: true,
        autoSubmit: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'offline-fixture',
        model: 'vision-model',
        slideScope: SlideScope.currentAndNext,
      );
      await _mount(
        tester,
        _page(AutomationPage(controller: controller)),
        scale,
      );
      await _capture(tester, 'settings-ai-$suffix');
      final dropdown = find.byType(DropdownButtonFormField<SlideScope>);
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      for (final label in ['不发送课件', '当前页课件', '当前页和后一页课件', '完整课件']) {
        expect(find.text(label).last, findsOneWidget);
      }
      await _capture(tester, 'settings-scopes-$suffix');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
