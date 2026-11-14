import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/automation_page.dart';
import 'package:ykt_helper/ui/course_pages.dart';
import 'package:ykt_helper/ui/live_page.dart';
import 'package:ykt_helper/ui/settings_page.dart';
import 'package:ykt_helper/ui/widgets.dart';

class _MemoryStore implements KeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _UiController extends AppController {
  int confirmations = 0;
  int detailLoads = 0;
  bool oldListLesson = false, oldDetailLesson = false;
  LessonDetail? detailResult;
  Slide? savedSlide;
  List<Slide>? gallerySlides;
  Presentation? exportedSlides;
  bool? exportedPptx;
  dynamic submittedAnswer;
  final pages = <int>[];
  final attendanceRequests = <String>[];
  List<Lesson>? lessonsResult;
  Future<AttendanceStatus> Function(Lesson)? attendanceLoader;
  _UiController()
    : super(store: _MemoryStore(), startTimers: false, connectSockets: false) {
    initialized = true;
  }
  @override
  Future<LocationCheckin> locationStatus(LiveClass live) async =>
      const LocationCheckin(
        signed: false,
        available: true,
        latitude: 31.2,
        longitude: 121.5,
        address: '课堂签到中心',
      );
  @override
  Future<bool> confirmLocation(
    LiveClass live,
    LocationCheckin confirmed,
  ) async {
    confirmations++;
    return true;
  }

  @override
  Future<LessonPage> loadLessons(Course course, int page) async {
    pages.add(page);
    if (lessonsResult != null) return LessonPage(lessonsResult!, false);
    return LessonPage([
      Lesson(
        id: 'lesson-$page',
        courseId: course.courseId,
        classroomId: course.classroomId,
        title: page == 0 ? '第一节课堂' : '第二节课堂',
        oldVersion: oldListLesson,
      ),
    ], page == 0);
  }

  @override
  Future<AttendanceStatus> loadAttendance(Lesson lesson) async {
    attendanceRequests.add(lesson.id);
    return attendanceLoader == null
        ? AttendanceStatus.unknown
        : await attendanceLoader!(lesson);
  }

  void changeAccount(Account? next) {
    account = next;
    notifyListeners();
  }

  @override
  Future<LessonDetail> loadDetail(Lesson lesson) async {
    detailLoads++;
    if (detailResult != null) return detailResult!;
    return LessonDetail(
      lesson: Lesson(
        id: lesson.id,
        courseId: lesson.courseId,
        classroomId: lesson.classroomId,
        title: lesson.title,
        oldVersion: oldDetailLesson,
      ),
    );
  }

  @override
  Future<void> saveSlide(Slide slide) async {
    savedSlide = slide;
  }

  @override
  Future<int> saveSlidesToGallery(List<Slide> slides) async {
    gallerySlides = slides;
    return slides.where((slide) => slide.imageUrl.isNotEmpty).length;
  }

  @override
  Future<void> exportSlides(
    Presentation deck, {
    required bool pptx,
    Rect? sharePositionOrigin,
  }) async {
    exportedSlides = deck;
    exportedPptx = pptx;
  }

  @override
  Future<void> submitAnswer(
    LiveClass live,
    Question question,
    dynamic answer,
  ) async {
    submittedAnswer = answer;
  }
}

LiveClass _classroom() => LiveClass(
  lesson: const Lesson(
    id: 'lesson',
    courseId: 'course',
    classroomId: 'classroom',
    title: '当前课堂',
    live: true,
  ),
  session: const ClassroomSession(
    userId: 'user',
    lessonId: 'lesson',
    bearer: 'test',
    lessonToken: 'test',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('ykt_helper/app_permissions');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          permissions,
          (_) async => {
            'camera': 'granted',
            'notifications': 'granted',
            'photos': 'notRequired',
            'battery': 'granted',
          },
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
  });
  testWidgets('后台刷新时首页不显示周期顶部进度条', (tester) async {
    final controller = _UiController()..busy = true;
    await tester.pumpWidget(RainApp(controller: controller));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('窄屏课堂标题位于导航栏并省略长标题', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const title = '很长的课程名称与完整课堂标题：高等数学第一教学班第十二次课堂微积分综合应用';
    final controller = _UiController();
    await tester.pumpWidget(
      MaterialApp(
        home: CourseLessonsPage(
          controller: controller,
          course: const Course(courseId: 'c', classroomId: 'r', name: title),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(find.text(title));
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(
      tester.widget<Text>(find.text(title)).overflow,
      TextOverflow.ellipsis,
    );
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.title, isNotNull);
    expect(appBar.bottom, isNull);
    expect(find.byTooltip(title), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('历史详情直接展示课件并区分相册保存和文件导出', (tester) async {
    final controller = _UiController();
    const lesson = Lesson(
      id: 'l',
      courseId: 'c',
      classroomId: 'r',
      title: '历史课堂',
    );
    const slide = Slide(
      id: 's',
      index: 0,
      imageUrl: 'https://example.com/slide.png',
    );
    controller.detailResult = const LessonDetail(
      lesson: lesson,
      presentations: [PresentationRef('deck', '重复课件入口')],
      reviewSlides: [slide],
      answersKnown: true,
      checkinText: '已签到',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LessonDetailPage(controller: controller, lesson: lesson),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('课堂回顾'), findsNothing);
    expect(find.text('课件'), findsNothing);
    expect(find.text('回放'), findsNothing);
    expect(find.text('重复课件入口'), findsNothing);
    expect(find.text('已签到'), findsOneWidget);
    expect(find.byTooltip('刷新详情'), findsNothing);
    expect(find.byType(ReviewSlideCard), findsOneWidget);
    await tester.tap(find.byTooltip('保存到系统相册'));
    await tester.pumpAndSettle();
    expect(controller.savedSlide, same(slide));
    expect(find.text('已保存到系统相册'), findsOneWidget);
    expect(controller.exportedSlides, isNull);
    await tester.tap(find.byTooltip('下载课件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部保存到系统相册'));
    await tester.pumpAndSettle();
    expect(controller.gallerySlides, [slide]);
    expect(controller.exportedSlides, isNull);
    await tester.tap(find.byTooltip('下载课件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出全部图片 ZIP'));
    await tester.pumpAndSettle();
    expect(controller.exportedSlides!.slides.single.imageUrl, slide.imageUrl);
    expect(controller.exportedPptx, isFalse);
    await tester.tap(find.byTooltip('下载课件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出完整 PPTX'));
    await tester.pumpAndSettle();
    expect(controller.exportedPptx, isTrue);
    expect(controller.detailLoads, 1);
    expect(find.byType(LessonDetailPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('已提交的零分答案仍显示本人答案和提交状态', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OwnAnswer(
            AnswerRecord(
              problemId: 'question-1',
              answer: ['B'],
              source: AnswerSource.server,
              score: 0,
            ),
          ),
        ),
      ),
    );
    expect(find.text('我的答案 · 已提交'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('得分：0'), findsOneWidget);
  });

  testWidgets('课堂签到状态独立显示且不从课堂凭证或位置签到推断', (tester) async {
    final controller = _UiController(), live = _classroom();
    live.location = const LocationCheckin(signed: true, available: true);
    Widget view() => MaterialApp(
      home: LivePage(controller: controller, classroom: live),
    );
    await tester.pumpWidget(view());
    expect(live.attendance, AttendanceStatus.unknown);
    expect(find.text('本节签到：${live.checkinText}'), findsOneWidget);
    live.attendance = AttendanceStatus.signed;
    await tester.pumpWidget(view());
    expect(find.text('本节签到：已签到'), findsOneWidget);
    live.attendance = AttendanceStatus.unsigned;
    await tester.pumpWidget(view());
    expect(find.text('本节签到：未签到'), findsOneWidget);
    live.attendance = AttendanceStatus.unknown;
    live.attendanceError = '签到状态读取失败';
    await tester.pumpWidget(view());
    expect(find.text('签到状态读取失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('生成的选择答案同步填入两张卡片且重建保留手工编辑', (tester) async {
    final controller = _UiController(), live = _classroom();
    controller.account = const Account(id: 'user', name: '测试');
    controller.classrooms[live.lesson.id] = live;
    const question = Question(
      id: 'draft-choice',
      body: '选择题',
      type: 1,
      options: {'A': '选项甲', 'B': '选项乙'},
    );
    live.answersKnown = true;
    live.activeProblemIds.add(question.id);
    live.draftAnswers[question.id] = ['A'];
    Widget view() => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              for (final key in ['current', 'history'])
                QuestionCard(
                  key: ValueKey(key),
                  controller: controller,
                  classroom: live,
                  question: question,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(view());
    var choices = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(choices.map((choice) => choice.value), [true, false, true, false]);
    expect(find.text('答案已填充，待确认提交'), findsNWidgets(2));
    await tester.tap(find.byType(CheckboxListTile).at(1));
    await tester.pumpWidget(view());
    choices = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(choices[1].value, isTrue);
    expect(live.draftAnswers[question.id], ['B']);
    expect(live.autoStates[question.id], '答案已修改，待确认提交');
    expect(choices.map((choice) => choice.value), [false, true, false, true]);
    await tester.tap(find.text('提交答案').first);
    await tester.pump();
    expect(controller.submittedAnswer, ['B']);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('生成的填空与主观答案填入编辑框且重建不覆盖修改', (tester) async {
    final controller = _UiController(), live = _classroom();
    controller.account = const Account(id: 'user', name: '测试');
    controller.classrooms[live.lesson.id] = live;
    const blank = Question(
      id: 'blank-draft',
      body: '填空题',
      type: 4,
      blankCount: 2,
    );
    const essay = Question(id: 'essay-draft', body: '主观题', type: 5);
    live.answersKnown = true;
    live.activeProblemIds.addAll([blank.id, essay.id]);
    live.draftAnswers[blank.id] = ['第一空', '第二空'];
    live.draftAnswers[essay.id] = {
      'content': '生成的主观回答',
      'pics': [],
      'videos': [],
    };
    Widget view() => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              QuestionCard(
                key: const ValueKey('blank'),
                controller: controller,
                classroom: live,
                question: blank,
              ),
              QuestionCard(
                key: const ValueKey('essay'),
                controller: controller,
                classroom: live,
                question: essay,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(view());
    expect(find.text('第一空'), findsOneWidget);
    expect(find.text('第二空'), findsOneWidget);
    expect(find.text('生成的主观回答'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '手动改写第一空');
    await tester.pumpWidget(view());
    expect(find.text('手动改写第一空'), findsOneWidget);
    expect(live.draftAnswers[blank.id], ['手动改写第一空', '第二空']);
    expect(live.autoStates[blank.id], '答案已修改，待确认提交');
    await tester.ensureVisible(find.byType(TextField).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '手动改写主观回答');
    await tester.pumpWidget(view());
    expect(live.draftAnswers[essay.id]['content'], '手动改写主观回答');
    expect(live.autoStates[essay.id], '答案已修改，待确认提交');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('主观题待批改记录显示本人正文', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OwnAnswer(
            AnswerRecord(
              problemId: 'question-2',
              answer: {'content': '我的主观题作答', 'pics': []},
              source: AnswerSource.server,
              score: -1,
            ),
          ),
        ),
      ),
    );
    expect(find.text('我的主观题作答'), findsOneWidget);
    expect(find.text('待批改'), findsOneWidget);
    expect(find.text('我的答案 · 已提交'), findsOneWidget);
  });

  testWidgets('底栏可切换课程动态设置', (tester) async {
    final controller = _UiController();
    await tester.pumpWidget(RainApp(controller: controller));
    expect(find.text('请在设置中登录'), findsOneWidget);
    expect(find.byTooltip('扫码进入课堂'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('自动化'), findsOneWidget);
    expect(find.byTooltip('扫码进入课堂'), findsNothing);
    await tester.tap(find.byIcon(Icons.class_outlined));
    await tester.pumpAndSettle();
    expect(find.byTooltip('扫码进入课堂'), findsOneWidget);
    expect(find.text('扫码进入课堂'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('初始化未完成时禁用登录和设置写入', (tester) async {
    final controller = _UiController()..initialized = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    expect(find.text('初始化中…'), findsOneWidget);
    final login = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('初始化中…'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(login.onPressed, isNull);
    await tester.pumpWidget(
      MaterialApp(home: AutomationPage(controller: controller)),
    );
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '自动答题'))
          .onChanged,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('手动入课时也显示后台运行失败提示', (tester) async {
    final controller = _UiController()..backgroundWarning = '后台运行未开启，请保持前台';
    await tester.pumpWidget(
      MaterialApp(
        home: LivePage(controller: controller, classroom: _classroom()),
      ),
    );
    expect(find.text('后台运行未开启，请保持前台'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('自动答题配置先编辑保存成功后才应用', (tester) async {
    final controller = _UiController();
    await tester.pumpWidget(
      MaterialApp(home: AutomationPage(controller: controller)),
    );
    await tester.tap(find.text('自动答题'));
    await tester.pumpAndSettle();
    expect(find.text('固定内容'), findsOneWidget);
    expect(controller.settings.autoAnswer, isFalse);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoAnswer, isFalse);
    expect(find.text('请填写固定答案后保存'), findsOneWidget);
    expect(find.text('设置已保存'), findsNothing);
    ScaffoldMessenger.of(
      tester.element(find.byType(AutomationPage)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    final answer = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '固定答案',
    );
    await tester.ensureVisible(answer);
    await tester.enterText(answer, 'A');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(controller.settings.autoAnswer, isTrue);
    expect(controller.settings.fixedAnswer, 'A');
    expect(find.text('设置已保存'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('课程从第零页起加载并能继续读取历史课堂', (tester) async {
    final controller = _UiController();
    controller.account = const Account(id: 'user', name: '学生');
    controller.courses = [
      const Course(
        courseId: 'course',
        classroomId: 'classroom',
        name: '全部课程测试',
      ),
    ];
    await tester.pumpWidget(RainApp(controller: controller));
    await tester.tap(find.text('全部课程测试'));
    await tester.pumpAndSettle();
    expect(controller.pages, [0]);
    expect(find.text('第一节课堂'), findsOneWidget);
    await tester.tap(find.text('加载更多课堂'));
    await tester.pumpAndSettle();
    expect(controller.pages, [0, 1]);
    expect(find.text('第一节课堂'), findsOneWidget);
    expect(find.text('第二节课堂'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('课堂列表只读独立签到状态且不加载整套详情', (tester) async {
    final controller = _UiController()
      ..account = const Account(id: 'attendance-user', name: '学生')
      ..lessonsResult = const [
        Lesson(id: 'signed', courseId: 'c', classroomId: 'r', title: '已签课堂'),
        Lesson(id: 'unsigned', courseId: 'c', classroomId: 'r', title: '缺席课堂'),
        Lesson(id: 'failed', courseId: 'c', classroomId: 'r', title: '报告异常课堂'),
        Lesson(
          id: 'legacy',
          courseId: 'c',
          classroomId: 'r',
          title: '旧课堂',
          oldVersion: true,
        ),
      ]
      ..attendanceLoader = (lesson) async {
        if (lesson.id == 'failed') throw const ApiFailure('报告暂不可用');
        return lesson.id == 'signed'
            ? AttendanceStatus.signed
            : AttendanceStatus.unsigned;
      };
    await tester.pumpWidget(
      MaterialApp(
        home: CourseLessonsPage(
          controller: controller,
          course: const Course(courseId: 'c', classroomId: 'r', name: '课程'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已签到'), findsOneWidget);
    expect(find.text('未签到'), findsOneWidget);
    expect(find.text('未同步'), findsNWidgets(2));
    expect(controller.attendanceRequests, ['signed', 'unsigned', 'failed']);
    expect(controller.detailLoads, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('列表签到读取最多三个并发且换账号忽略迟到结果', (tester) async {
    final pending = <String, Completer<AttendanceStatus>>{};
    final controller = _UiController()
      ..account = const Account(id: 'attendance-a', name: '学生甲')
      ..lessonsResult = [
        for (var i = 0; i < 7; i++)
          Lesson(
            id: 'pending-$i',
            courseId: 'c',
            classroomId: 'r',
            title: '课堂$i',
          ),
      ]
      ..attendanceLoader = (lesson) =>
          (pending[lesson.id] = Completer<AttendanceStatus>()).future;
    await tester.pumpWidget(
      MaterialApp(
        home: CourseLessonsPage(
          controller: controller,
          course: const Course(courseId: 'c', classroomId: 'r', name: '课程'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(pending.length, 3);
    pending['pending-0']!.complete(AttendanceStatus.signed);
    await tester.pumpAndSettle();
    expect(pending.length, 4);
    expect(find.text('已签到'), findsOneWidget);
    controller.changeAccount(const Account(id: 'attendance-b', name: '学生乙'));
    await tester.pumpAndSettle();
    for (final completion in pending.values) {
      if (!completion.isCompleted) completion.complete(AttendanceStatus.signed);
    }
    await tester.pumpAndSettle();
    expect(find.text('账号已变更，请返回课程列表'), findsOneWidget);
    expect(find.text('已签到'), findsNothing);
    expect(pending.length, 4);
    expect(controller.detailLoads, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('下拉刷新重新读取签到状态', (tester) async {
    var refreshed = false;
    final controller = _UiController()
      ..account = const Account(id: 'attendance-refresh', name: '学生')
      ..lessonsResult = const [
        Lesson(id: 'refresh', courseId: 'c', classroomId: 'r', title: '刷新课堂'),
      ]
      ..attendanceLoader = (_) async =>
          refreshed ? AttendanceStatus.signed : AttendanceStatus.unknown;
    await tester.pumpWidget(
      MaterialApp(
        home: CourseLessonsPage(
          controller: controller,
          course: const Course(courseId: 'c', classroomId: 'r', name: '课程'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未同步'), findsOneWidget);
    refreshed = true;
    unawaited(
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show(),
    );
    await tester.pumpAndSettle();
    expect(controller.attendanceRequests.length, 2);
    expect(find.text('已签到'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('已明确标记的旧版课堂在列表提示且不请求详情', (tester) async {
    final controller = _UiController()..oldListLesson = true;
    await tester.pumpWidget(
      MaterialApp(
        home: CourseLessonsPage(
          controller: controller,
          course: const Course(courseId: 'c', classroomId: 'r', name: '课程'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧版课堂'), findsOneWidget);
    await tester.tap(find.text('第一节课堂'));
    await tester.pumpAndSettle();
    expect(find.text('此旧版课堂暂不支持查看详情，请使用官方客户端查看。'), findsOneWidget);
    expect(controller.detailLoads, 0);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('课堂信息返回旧版标记时详情明确显示未支持提示', (tester) async {
    final controller = _UiController()..oldDetailLesson = true;
    await tester.pumpWidget(
      MaterialApp(
        home: LessonDetailPage(
          controller: controller,
          lesson: const Lesson(
            id: 'legacy',
            courseId: 'c',
            classroomId: 'r',
            title: '历史课堂',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.detailLoads, 1);
    expect(find.text('此旧版课堂暂不支持查看详情，请使用官方客户端查看。'), findsOneWidget);
    expect(find.text('签到状态待确认'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('远端状态未知时保留警告并允许手动提交', (tester) async {
    final controller = _UiController(), live = _classroom();
    final question = Question(
      id: 'question',
      body: '<p>题干</p>',
      type: 1,
      options: const {'A': '选项A', 'B': '选项B'},
      dt: DateTime.now().millisecondsSinceEpoch,
      limit: 60,
    );
    live.activeProblemIds.add(question.id);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QuestionCard(
              controller: controller,
              classroom: live,
              question: question,
            ),
          ),
        ),
      ),
    );
    expect(find.text('作答状态尚未确认。提交前请确认没有在其他设备作答。'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('类型6判断题按单选选项提交', (tester) async {
    final controller = _UiController(), live = _classroom();
    final question = Question(
      id: 'judgement',
      body: '判断题',
      type: 6,
      options: const {'A': '正确', 'B': '错误'},
      dt: DateTime.now().millisecondsSinceEpoch,
      limit: 60,
    );
    live.activeProblemIds.add(question.id);
    live.answersKnown = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QuestionCard(
              controller: controller,
              classroom: live,
              question: question,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    await tester.tap(find.byType(CheckboxListTile).at(0));
    await tester.pump();
    await tester.tap(find.byType(CheckboxListTile).at(1));
    await tester.pump();
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(0))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(1))
          .value,
      isTrue,
    );
    await tester.tap(find.text('提交答案'));
    await tester.pump();
    expect(controller.submittedAnswer, ['B']);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('投票允许选择两项并在达到上限后保留取消能力', (tester) async {
    final controller = _UiController(), live = _classroom();
    final question = Question(
      id: 'poll',
      body: '投票题',
      type: 3,
      selectionLimit: 2,
      options: const {'A': '选项一', 'B': '选项二', 'C': '选项三'},
      dt: DateTime.now().millisecondsSinceEpoch,
      limit: 60,
    );
    live.activeProblemIds.add(question.id);
    live.answersKnown = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QuestionCard(
              controller: controller,
              classroom: live,
              question: question,
            ),
          ),
        ),
      ),
    );
    for (final index in [0, 1, 2]) {
      await tester.tap(find.byType(CheckboxListTile).at(index));
      await tester.pump();
    }
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(0))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(1))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(2))
          .value,
      isFalse,
    );
    expect(find.text('最多选择 2 项'), findsNWidgets(2));
    await tester.tap(find.byType(CheckboxListTile).at(0));
    await tester.pump();
    await tester.tap(find.byType(CheckboxListTile).at(2));
    await tester.pump();
    await tester.ensureVisible(find.text('提交答案'));
    await tester.tap(find.text('提交答案'));
    await tester.pump();
    expect(controller.submittedAnswer, ['B', 'C']);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('位置签到确认前不会提交坐标', (tester) async {
    final controller = _UiController(), live = _classroom();
    await tester.pumpWidget(
      MaterialApp(
        home: LivePage(controller: controller, classroom: live),
      ),
    );
    await tester.tap(find.text('位置签到'));
    await tester.pumpAndSettle();
    expect(find.textContaining('使用服务器签到中心，并非手机定位'), findsOneWidget);
    expect(controller.confirmations, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.confirmations, 0);
    await tester.tap(find.text('位置签到'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认签到'));
    await tester.pumpAndSettle();
    expect(controller.confirmations, 1);
    expect(find.text('位置签到成功'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
