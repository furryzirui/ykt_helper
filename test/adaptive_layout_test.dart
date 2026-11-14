import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/course_pages.dart';
import 'package:ykt_helper/ui/live_page.dart';
import 'package:ykt_helper/ui/login_page.dart';
import 'package:ykt_helper/ui/widgets.dart';

const _screenshots = bool.fromEnvironment('GENERATE_SCREENSHOTS');
const _slideUrl = 'https://offline.invalid/adaptive-slide.png';
const _lesson = Lesson(
  id: 'lesson',
  courseId: 'course',
  classroomId: 'classroom',
  title: '横屏课堂 · 微积分基础',
);
const _question = Question(
  id: 'q',
  type: 5,
  body: '请简述导数的几何意义。',
  dt: 0,
  limit: 0,
);
const _slides = [
  Slide(id: 'slide-1', index: 0, imageUrl: _slideUrl, question: _question),
  Slide(id: 'slide-2', index: 1, imageUrl: _slideUrl),
  Slide(id: 'slide-3', index: 2, imageUrl: _slideUrl),
];

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Api extends RainApi {
  final qr = Completer<Json>();
  @override
  Future<Json> createQr() => qr.future;
  @override
  void cancelQr() {}
}

class _Controller extends AppController {
  List<Slide> reviewSlides = _slides;
  final savedSlideIds = <String>[];

  @override
  Future<void> saveSlide(Slide slide) async => savedSlideIds.add(slide.id);

  _Controller()
    : super(
        api: _Api(),
        store: _Store(),
        startTimers: false,
        connectSockets: false,
      ) {
    initialized = true;
    account = const Account(id: 'user', name: '测试学生', school: '大学');
    courses = const [
      Course(
        courseId: 'course',
        classroomId: 'classroom',
        name: '高等数学',
        teacher: '教师',
        classroomName: '第一教学班',
      ),
      Course(
        courseId: 'course2',
        classroomId: 'classroom2',
        name: '线性代数',
        teacher: '教师',
        classroomName: '第二教学班',
      ),
    ];
  }
  @override
  Future<LessonPage> loadLessons(Course course, int page) async =>
      const LessonPage([_lesson], false);
  @override
  Future<AttendanceStatus> loadAttendance(Lesson lesson) async =>
      AttendanceStatus.signed;
  @override
  Future<LessonDetail> loadDetail(Lesson lesson) async => LessonDetail(
    lesson: _lesson,
    checkinText: '已签到',
    teacher: '教师甲',
    answersKnown: true,
    reviewSlides: reviewSlides,
    answers: {
      'q': AnswerRecord(
        problemId: 'q',
        answer: {'content': '切线的斜率'},
        source: AnswerSource.server,
      ),
    },
  );
}

LiveClass _live() =>
    LiveClass(
        lesson: _lesson,
        session: const ClassroomSession(
          userId: 'user',
          lessonId: 'lesson',
          bearer: 'test',
          lessonToken: 'test',
        ),
      )
      ..presentationId = 'deck'
      ..presentations['deck'] = const Presentation(
        id: 'deck',
        title: '导数与微分',
        slides: _slides,
      )
      ..questions['q'] = _question
      ..activeProblemIds.add('q')
      ..answersKnown = true
      ..attendance = AttendanceStatus.signed
      ..connectionLabel = '已连接';

Future<Uint8List> _image() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 640, 12),
    Paint()..color = Colors.teal,
  );
  final painter = TextPainter(
    text: const TextSpan(
      text: '导数的几何意义',
      style: TextStyle(fontFamily: 'Roboto', color: Colors.teal, fontSize: 34),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, const Offset(36, 42));
  painter.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(640, 360);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _cache(WidgetTester tester) async {
  final info = await tester.runAsync(() async {
    final data = await _image();
    final completer = Completer<ImageInfo>();
    ui.decodeImageFromList(
      data,
      (image) => completer.complete(ImageInfo(image: image)),
    );
    return completer.future;
  });
  PaintingBinding.instance.imageCache.putIfAbsent(
    const NetworkImage(_slideUrl),
    () => OneFrameImageStreamCompleter(Future.value(info!)),
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget page,
  Size size,
  double scale,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await _cache(tester);
  await tester.pumpWidget(
    MaterialApp(theme: rainTheme(Brightness.light), home: page),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final path = Directory('.workspace-bootstrap/qa-1.0.1');
    await path.create(recursive: true);
    await File(
      '${path.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!_screenshots) return;
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
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          ))
          .load();
    }
    final font = File(
      '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyh.ttc',
    );
    if (await font.exists()) {
      await (FontLoader('Roboto')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
    }
  });

  for (final size in [
    const Size(360, 800),
    const Size(1280, 800),
    const Size(1024, 768),
    const Size(800, 400),
  ]) {
    for (final scale in [1.0, 1.5]) {
      final wide = size.width >= 760;
      final suffix = '${size.width.toInt()}x${size.height.toInt()}-$scale';
      testWidgets('课堂回顾完整PPT和独立选页 $suffix', (tester) async {
        final controller = _Controller();
        await _mount(
          tester,
          LessonDetailPage(controller: controller, lesson: _lesson),
          size,
          scale,
        );
        expect(tester.takeException(), isNull);
        if (wide) {
          expect(
            find.byKey(const ValueKey('review-wide-layout')),
            findsOneWidget,
          );
          final viewport = tester.getRect(find.byType(SlideViewport));
          expect(viewport.height, greaterThan(45));
          expect(viewport.right, lessThanOrEqualTo(size.width));
          expect(viewport.bottom, lessThan(size.height));
          expect(find.text('切线的斜率'), findsOneWidget);
          await tester.tap(find.byTooltip('下一页'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<SlideViewport>(find.byType(SlideViewport)).slide!.id,
            'slide-2',
          );
          await tester.tap(find.byTooltip('上一页'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<SlideViewport>(find.byType(SlideViewport)).slide!.id,
            'slide-1',
          );
        } else {
          expect(find.byType(ReviewSlideCard), findsWidgets);
          expect(find.byType(SlideViewport), findsNothing);
        }
        await _capture(tester, 'review-$suffix');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });

      testWidgets('实时课堂课件与作答面板可同时使用 $suffix', (tester) async {
        final controller = _Controller(), live = _live();
        controller.classrooms[live.lesson.id] = live;
        await _mount(
          tester,
          LivePage(controller: controller, classroom: live),
          size,
          scale,
        );
        expect(tester.takeException(), isNull);
        if (wide) {
          expect(
            find.byKey(const ValueKey('live-wide-layout')),
            findsOneWidget,
          );
          final slideRect = tester.getRect(find.byType(SlideViewport));
          final cardRect = tester.getRect(find.byType(QuestionCard).first);
          expect(cardRect.left, greaterThan(slideRect.right));
          expect(slideRect.height, greaterThan(80));
          await tester.tap(find.byTooltip('下一页'));
          await tester.pumpAndSettle();
          expect(live.slideIndex, 1);
          expect(live.followTeacher, isFalse);
          await tester.tap(find.byTooltip('上一页'));
          await tester.pumpAndSettle();
          expect(live.slideIndex, 0);
          final field = find.byType(TextField).first;
          await tester.ensureVisible(field);
          await tester.enterText(field, '切线的斜率');
          await tester.pump();
          expect((live.draftAnswers['q'] as Map)['content'], '切线的斜率');
        } else {
          expect(find.byKey(const ValueKey('live-wide-layout')), findsNothing);
        }
        await _capture(tester, 'live-$suffix');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }

  testWidgets('大屏课程与课堂详情采用分栏并保留列表签到状态', (tester) async {
    final controller = _Controller();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RainApp(controller: controller, startupChecks: false),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    final first = tester.getRect(find.text('高等数学'));
    final second = tester.getRect(find.text('线性代数'));
    expect(first.top, second.top);
    expect(second.left, greaterThan(first.right));
    await tester.tap(find.text('高等数学'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lesson-master-detail')), findsOneWidget);
    expect(find.text('已签到'), findsOneWidget);
    await _cache(tester);
    await tester.tap(find.text(_lesson.title));
    await tester.pumpAndSettle();
    expect(
      tester.widget<LessonDetailPage>(find.byType(LessonDetailPage)).embedded,
      isTrue,
    );
    expect(find.byType(CourseLessonsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'master-detail-1280x800');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final embedded in [false, true]) {
    for (final size in [const Size(1280, 800), const Size(800, 480)]) {
      testWidgets('横屏下载菜单保存当前页且预览标出题目 $size embedded=$embedded', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final controller = _Controller();
        await _mount(
          tester,
          LessonDetailPage(
            controller: controller,
            lesson: _lesson,
            embedded: embedded,
          ),
          size,
          1,
        );
        expect(
          find.byKey(const ValueKey('review-wide-layout')),
          findsOneWidget,
        );
        final problemPage = find.byKey(const ValueKey('review-thumbnail-0'));
        final ordinaryPage = find.byKey(const ValueKey('review-thumbnail-1'));
        expect(
          find.descendant(
            of: problemPage,
            matching: find.byIcon(Icons.quiz_outlined),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: problemPage, matching: find.text('主观题')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: ordinaryPage,
            matching: find.byIcon(Icons.quiz_outlined),
          ),
          findsNothing,
        );
        expect(find.byIcon(Icons.save_alt_rounded), findsNothing);
        expect(find.byTooltip('下载课件'), findsOneWidget);

        await tester.tap(find.byTooltip('下载课件'));
        await tester.pumpAndSettle();
        final items = tester
            .widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>),
            )
            .toList();
        expect(items.first.value, 'image');
        expect(items.first.enabled, isTrue);
        await tester.tap(find.byWidget(items.first));
        await tester.pumpAndSettle();
        expect(controller.savedSlideIds, ['slide-1']);

        await tester.tap(find.byTooltip('下一页'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下载课件'));
        await tester.pumpAndSettle();
        final secondItems = tester
            .widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>),
            )
            .toList();
        await tester.tap(find.byWidget(secondItems.first));
        await tester.pumpAndSettle();
        expect(controller.savedSlideIds, ['slide-1', 'slide-2']);
        expect(find.byIcon(Icons.save_alt_rounded), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }

  testWidgets('无图片的当前页禁用横屏菜单单页保存，其余导出仍可用', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = _Controller()
      ..reviewSlides = [
        _slides.first,
        const Slide(
          id: 'text-only',
          index: 1,
          imageUrl: '',
          question: _question,
        ),
      ];
    await _mount(
      tester,
      LessonDetailPage(controller: controller, lesson: _lesson),
      const Size(1180, 800),
      1,
    );
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下载课件'));
    await tester.pumpAndSettle();
    final items = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .toList();
    expect(items.first.value, 'image');
    expect(items.first.enabled, isFalse);
    expect(items.skip(1).every((item) => item.enabled), isTrue);
    expect(controller.savedSlideIds, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('竖屏仍逐页保存且下载菜单不增加单页入口', (tester) async {
    final controller = _Controller();
    await _mount(
      tester,
      LessonDetailPage(controller: controller, lesson: _lesson),
      const Size(360, 800),
      1,
    );
    expect(find.byType(ReviewSlideCard), findsWidgets);
    expect(find.byIcon(Icons.save_alt_rounded), findsWidgets);
    await tester.tap(find.byTooltip('下载课件'));
    await tester.pumpAndSettle();
    final items = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .toList();
    expect(items.any((item) => item.value == 'image'), isFalse);
    expect(items.first.value, 'album');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('实时课堂旋转后保留手工草稿与当前页', (tester) async {
    final controller = _Controller(), live = _live();
    controller.classrooms[live.lesson.id] = live;
    await _mount(
      tester,
      LivePage(controller: controller, classroom: live),
      const Size(1024, 768),
      1,
    );
    final field = find.byType(TextField).first;
    await tester.ensureVisible(field);
    await tester.enterText(field, '旋转前草稿');
    await tester.pump();
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-wide-layout')), findsNothing);
    await tester.scrollUntilVisible(
      find.byType(TextField).first,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('旋转前草稿'), findsOneWidget);
    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-wide-layout')), findsOneWidget);
    expect(find.text('旋转前草稿'), findsOneWidget);
    expect(live.slideIndex, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final live in [false, true]) {
    testWidgets('${live ? '动态' : '课程'}未登录可直接进入登录页', (tester) async {
      final controller = _Controller()..account = null;
      await _mount(
        tester,
        Scaffold(
          body: live
              ? LiveListPage(controller: controller)
              : CoursesPage(controller: controller),
        ),
        const Size(360, 800),
        1,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, '登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoginPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
