import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/background_runtime.dart';
import 'package:ykt_helper/services/classroom_notifications.dart';

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Runtime extends BackgroundRuntime {
  @override
  bool get enabled => true;
  @override
  Future<bool> setEnabled(bool enabled) async => true;
}

class _Notifications extends ClassroomNotifications {
  final shown = <({String key, String body, String lesson, String problem})>[];
  final cancelled = <String>[];
  int clears = 0;
  bool allowed = true;
  Completer<bool>? pending;
  @override
  Future<bool> show({
    required String key,
    required String title,
    required String body,
    required String lessonId,
    required String problemId,
  }) async {
    shown.add((key: key, body: body, lesson: lessonId, problem: problemId));
    return await pending?.future ?? allowed;
  }

  @override
  Future<void> cancel(String key) async => cancelled.add(key);
  @override
  Future<void> cancelAll() async => clears++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController controller;
  late _Notifications notifications;
  late LiveClass live;
  late Question question;

  void pulse() => controller.followTeacher(live, false);

  setUp(() {
    notifications = _Notifications();
    controller = AppController(
      store: _Store(),
      background: _Runtime(),
      notifications: notifications,
      startTimers: false,
      connectSockets: false,
    )..account = const Account(id: 'user', name: '学生');
    question = Question(
      id: 'q',
      body: '题干不进入通知',
      type: 5,
      dt: DateTime.now().millisecondsSinceEpoch - 1000,
      limit: -1,
    );
    live =
        LiveClass(
            lesson: const Lesson(
              id: 'l',
              courseId: 'c',
              classroomId: 'r',
              title: '课堂',
              live: true,
            ),
            session: const ClassroomSession(
              userId: 'user',
              lessonId: 'l',
              bearer: 'test',
              lessonToken: 'test',
            ),
          )
          ..questions['q'] = question
          ..activeProblemIds.add('q')
          ..answersKnown = true;
    controller.classrooms['l'] = live;
  });
  tearDown(() => controller.dispose());

  test('manual questions notify only in background and deduplicate', () async {
    pulse();
    expect(notifications.shown, isEmpty);
    controller.setForeground(false);
    await Future<void>.delayed(Duration.zero);
    expect(notifications.shown.single.body, contains('手动作答'));
    expect(notifications.shown.single.lesson, 'l');
    expect(notifications.shown.single.problem, 'q');
    expect(notifications.shown.single.body, isNot(contains(question.body)));
    pulse();
    pulse();
    expect(notifications.shown, hasLength(1));
  });

  test('unpublished preparations wait until answering is open', () {
    controller.settings = AppSettings(autoAnswer: true);
    live.questions['q'] = const Question(id: 'q', body: '', type: 5);
    live.activeProblemIds.clear();
    live.draftAnswers['q'] = {'content': 'prepared'};
    controller.setForeground(false);
    expect(notifications.shown, isEmpty);
    live.questions['q'] = question;
    live.activeProblemIds.add('q');
    pulse();
    expect(notifications.shown.single.body, contains('确认提交'));
  });

  test(
    'a rejected native delivery can be retried after permission or visibility changes',
    () async {
      notifications.allowed = false;
      controller.setForeground(false);
      await Future<void>.delayed(Duration.zero);
      notifications.allowed = true;
      pulse();
      await Future<void>.delayed(Duration.zero);
      pulse();
      expect(notifications.shown, hasLength(2));
    },
  );

  test('ready drafts and failed automatic work have distinct reminders', () {
    controller.settings = AppSettings(autoAnswer: true);
    live.draftAnswers['q'] = {'content': 'draft'};
    controller.setForeground(false);
    expect(notifications.shown.single.body, contains('确认提交'));
    controller.settings.autoSubmit = true;
    live.autoStates['q'] = '答案已填充，30 秒后自动提交';
    pulse();
    expect(notifications.shown, hasLength(1));
    live.autoStates['q'] = '自动答题未完成：服务暂不可用';
    pulse();
    pulse();
    expect(notifications.shown, hasLength(2));
    expect(notifications.shown.last.body, contains('手动处理'));
  });

  test(
    'submission, timeout and foreground dismiss the outstanding reminder',
    () {
      controller.setForeground(false);
      final key = notifications.shown.single.key;
      live.answers['q'] = const AnswerRecord(
        problemId: 'q',
        answer: {'content': 'answer'},
        source: AnswerSource.local,
      );
      pulse();
      expect(notifications.cancelled, contains(key));
      live.answers.clear();
      live.questions['q'] = question.launched(question.dt + 1, -1);
      pulse();
      final second = notifications.shown.last.key;
      live.closedAtSequence['q'] = 1;
      pulse();
      expect(notifications.cancelled, contains(second));
      live.closedAtSequence.clear();
      live.questions['q'] = question.launched(question.dt + 2, -1);
      pulse();
      final third = notifications.shown.last.key;
      controller.setForeground(true);
      expect(notifications.cancelled, contains(third));
    },
  );

  test(
    'a late notification is cancelled after the app returns to foreground',
    () async {
      notifications.pending = Completer<bool>();
      controller.setForeground(false);
      controller.setForeground(true);
      notifications.pending!.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(notifications.cancelled, contains(notifications.shown.single.key));
    },
  );

  test('classroom ended and already submitted questions never notify', () {
    live.ended = true;
    controller.setForeground(false);
    expect(notifications.shown, isEmpty);
    live.ended = false;
    live.answers['q'] = const AnswerRecord(
      problemId: 'q',
      answer: [],
      source: AnswerSource.server,
    );
    pulse();
    expect(notifications.shown, isEmpty);
  });
}
