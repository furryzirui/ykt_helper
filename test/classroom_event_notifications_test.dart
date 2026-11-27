import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/classroom_notifications.dart';
import 'automation_test.dart' as fixtures;

class _Runtime extends fixtures.NoBackground {
  @override
  bool get enabled => true;
}

class _Api extends fixtures.FakeRain {
  bool locationSigned = false;
  bool failEntry = false;
  List<Lesson> activeLessons = [];
  Object? locationError;
  @override
  Future<List<Lesson>> liveLessons() async => activeLessons;
  @override
  Future<ClassroomSession> checkin(String lessonId) async {
    if (failEntry) throw const ApiFailure('签到进入失败');
    return super.checkin(lessonId);
  }

  @override
  Future<LocationCheckin> locationStatus(ClassroomSession session) async {
    if (locationError != null) throw locationError!;
    return LocationCheckin(signed: locationSigned, available: false);
  }
}

class _Notifications extends ClassroomNotifications {
  final shown = <({String key, String body, String problem})>[];
  final cancelled = <String>[];
  Completer<bool>? pending;
  Completer<bool>? pendingQuestion;
  final active = <String, String>{};
  @override
  Future<bool> show({
    required String key,
    required String title,
    required String body,
    required String lessonId,
    required String problemId,
  }) async {
    shown.add((key: key, body: body, problem: problemId));
    final delivered =
        await (problemId.isNotEmpty ? pendingQuestion?.future : null) ??
        await pending?.future ??
        true;
    if (delivered) active[key] = body;
    return delivered;
  }

  @override
  Future<void> cancel(String key) async {
    cancelled.add(key);
    active.remove(key);
  }

  @override
  Future<void> cancelAll() async => active.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const lesson = Lesson(
    id: 'l',
    courseId: 'c',
    classroomId: 'cl',
    title: '课程',
    live: true,
  );
  const question = Question(
    id: 'q',
    body: 'private question',
    type: 1,
    options: {'A': '2', 'B': '3', 'C': '4'},
  );
  late AppController controller;
  late _Api api;
  late _Notifications notifications;
  late fixtures.BatchAi ai;
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  Future<LiveClass> enter({bool background = true}) async {
    if (background) controller.setForeground(false);
    final live = await controller.enter(lesson);
    await controller.processEvent(live, {
      'op': 'hello',
      'presentation': 'p',
      'slideindex': 1,
    });
    await settle();
    return live;
  }

  setUp(() {
    api = _Api();
    api.decks['p'] = const Presentation(
      id: 'p',
      title: '课件',
      slides: [Slide(id: 's', index: 0, imageUrl: '', question: question)],
    );
    notifications = _Notifications();
    ai = fixtures.BatchAi();
    controller =
        AppController(
            api: api,
            store: fixtures.MemoryStore(),
            ai: ai,
            background: _Runtime(),
            autostart: const fixtures.NoAutostart(),
            notifications: notifications,
            startTimers: false,
            connectSockets: false,
          )
          ..account = const Account(id: 'u', name: '学生')
          ..settings = AppSettings(autoAnswer: true, autoSubmit: true);
  });
  tearDown(() => controller.dispose());

  test(
    'background entry and signed state notify once without question identity',
    () async {
      api.attendanceValue = AttendanceStatus.signed;
      final live = await enter();
      await controller.syncAttendance(live);
      await settle();
      expect(
        notifications.shown.where((event) => event.body == '课堂签到成功'),
        hasLength(1),
      );
      expect(
        notifications.shown
            .firstWhere((event) => event.body == '课堂签到成功')
            .problem,
        '',
      );
      expect(
        notifications.shown.every(
          (event) => !event.body.contains('private question'),
        ),
        true,
      );
    },
  );

  test(
    'background preparation, assignment and successful submission report transitions',
    () async {
      controller.settings.answerMode = AnswerMode.ai;
      final live = await enter();
      expect(
        notifications.shown.any((event) => event.body.contains('正在使用 AI 自动作答')),
        true,
      );
      ai.requests['q']!.single.complete('A');
      await settle();
      expect(
        notifications.shown.any((event) => event.body.contains('答案已填充，等待开始作答')),
        true,
      );
      await controller.processEvent(live, {
        'op': 'unlockproblem',
        'problem': {
          'prob': 'q',
          'pres': 'p',
          'dt': controller.now().millisecondsSinceEpoch,
          'limit': 120,
        },
      });
      await settle();
      expect(
        notifications.shown.any(
          (event) =>
              event.key == 'u:l:assignment:q' && event.body.contains('老师已布置题目'),
        ),
        true,
      );
      await controller.submitAnswer(live, live.questions['q']!, ['A']);
      await settle();
      expect(
        notifications.shown.any((event) => event.body.contains('答案已提交')),
        true,
      );
      expect(notifications.active.containsKey('u:l:assignment:q'), isFalse);
      final count = notifications.shown.length;
      controller.followTeacher(live, false);
      controller.followTeacher(live, true);
      await settle();
      expect(notifications.shown, hasLength(count));
      await controller.processEvent(live, {'op': 'lessonfinished'});
      await settle();
      expect(notifications.shown.last.body, '课堂已结束');
    },
  );

  test('foreground classroom work emits no event notifications', () async {
    final live = await enter(background: false);
    await controller.processEvent(live, {'op': 'lessonfinished'});
    await settle();
    expect(notifications.shown, isEmpty);
  });

  test(
    'background automatic entry failures notify once across repeated polls',
    () async {
      controller.settings
        ..autoEnter = true
        ..autoLocationCheckin = true;
      api.activeLessons = [lesson];
      api.failEntry = true;
      controller.setForeground(false);
      await controller.refresh();
      await settle();
      await controller.refresh();
      await settle();
      expect(
        notifications.shown.where((event) => event.body == '自动签到进入失败，请打开课堂处理'),
        hasLength(1),
      );
      expect(notifications.shown.single.problem, '');
    },
  );

  test(
    'position success notifies once per state and repeats do not notify',
    () async {
      final live = await enter();
      api.locationSigned = true;
      await controller.locationStatus(live);
      await settle();
      await controller.locationStatus(live);
      await settle();
      expect(
        notifications.shown.where((event) => event.body == '位置签到成功'),
        hasLength(1),
      );
    },
  );

  test(
    'automatic position errors notify once instead of every polling check',
    () async {
      final live = await enter();
      controller.settings
        ..autoEnter = true
        ..autoLocationCheckin = true;
      api.locationError = const ApiFailure('位置状态失败');
      await controller.syncAttendance(live);
      await settle();
      await controller.syncAttendance(live);
      await settle();
      expect(
        notifications.shown.where((event) => event.body.contains('自动位置签到失败')),
        hasLength(1),
      );
    },
  );

  test('late event delivery is dismissed on foreground transition', () async {
    notifications.pending = Completer<bool>();
    await enter();
    controller.setForeground(true);
    notifications.pending!.complete(true);
    await settle();
    for (final event in notifications.shown) {
      expect(notifications.cancelled, contains(event.key));
    }
  });

  test(
    'a rejected old delivery cannot erase the same account new classroom event',
    () async {
      controller.settings = AppSettings();
      final previousDelivery = Completer<bool>();
      notifications.pending = previousDelivery;
      await enter();
      expect(
        notifications.shown.where((event) => event.body == '已进入课堂，正在确认签到状态'),
        hasLength(1),
      );
      await controller.logout();
      controller.account = const Account(id: 'u', name: '同一账号重新登录');
      notifications.pending = null;
      await controller.enter(lesson);
      await settle();
      previousDelivery.complete(false);
      await settle();
      expect(
        notifications.shown.where((event) => event.body == '已进入课堂，正在确认签到状态'),
        hasLength(2),
        reason: '旧会话失败回调不能删除新会话相同 key/state 的通知',
      );
    },
  );

  test(
    'a pending generation notification is cancelled when the classroom ends',
    () async {
      controller.settings.answerMode = AnswerMode.ai;
      notifications.pendingQuestion = Completer<bool>();
      final live = await enter();
      final pendingGeneration = notifications.shown.singleWhere(
        (event) => event.body.contains('正在使用 AI 自动作答'),
      );
      await controller.processEvent(live, {'op': 'lessonfinished'});
      await settle();
      notifications.pendingQuestion!.complete(true);
      ai.requests['q']!.single.complete('A');
      await settle();
      expect(notifications.cancelled, contains(pendingGeneration.key));
      expect(notifications.active.containsKey(pendingGeneration.key), isFalse);
      expect(
        notifications.shown.where((event) => event.problem.isNotEmpty),
        hasLength(1),
        reason: '结束后的迟到 AI 结果不能追加填充或提交状态通知',
      );
      expect(notifications.active.values, contains('课堂已结束'));
    },
  );
}
