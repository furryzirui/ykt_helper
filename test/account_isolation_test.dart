import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';
import 'package:ykt_helper/services/ai_request_scheduler.dart';
import 'package:ykt_helper/services/background_runtime.dart';

class DelayedStore implements KeyValueStore {
  final values = <String, String>{};
  final pendingReads = <String, Completer<String?>>{};
  final readsStarted = <String, Completer<void>>{};

  @override
  Future<String?> read(String key) {
    final started = readsStarted[key];
    if (started != null && !started.isCompleted) started.complete();
    return pendingReads[key]?.future ?? Future.value(values[key]);
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class NoBackground extends BackgroundRuntime {
  @override
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {}
  @override
  Future<BackgroundRuntimeState?> status() async => null;

  bool active = false;

  @override
  bool get enabled => active;

  @override
  Future<bool> setEnabled(bool enabled) async {
    active = enabled;
    return true;
  }
}

class IsolationRain extends RainApi {
  @override
  Future<AttendanceStatus> attendance(Lesson lesson) async =>
      AttendanceStatus.unknown;
  Account accountForProfile = const Account(id: 'a', name: 'A');
  int cookieExports = 0, submissions = 0;
  final decks = <String, Presentation>{};
  final answerResponses = <String, Completer<Map<String, AnswerRecord>>>{};
  final answerReadsStarted = <String, Completer<void>>{};
  final answerRequests = <String>[];

  @override
  Future<Account> profile() async {
    userId = accountForProfile.id;
    return accountForProfile;
  }

  @override
  Future<String> exportCookies() async {
    cookieExports++;
    return '[]';
  }

  @override
  Future<List<Course>> courses() async => [];

  @override
  Future<List<Lesson>> liveLessons() async => [];

  @override
  Future<ClassroomSession> checkin(String lessonId) async => ClassroomSession(
    userId: userId!,
    lessonId: lessonId,
    bearer: 'http-$lessonId',
    lessonToken: 'socket-$lessonId',
  );

  @override
  Future<Presentation> presentation(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
    bool withAnswers = true,
  }) async => decks[presentationId]!;

  @override
  Future<Map<String, AnswerRecord>> ownAnswers(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
  }) {
    answerRequests.add(presentationId);
    final started = answerReadsStarted[presentationId];
    if (started != null && !started.isCompleted) started.complete();
    return answerResponses[presentationId]?.future ?? Future.value({});
  }

  @override
  Future<void> submit(
    ClassroomSession session,
    Question question,
    dynamic answer,
  ) async {
    submissions++;
  }

  @override
  Future<void> logout() async {
    userId = null;
  }
}

class WaitingAi extends AiAnswerService {
  final started = Completer<void>();
  final answer = Completer<String>();

  @override
  Future<String> generate({
    required AppSettings settings,
    required Question question,
    required List<Slide> slides,
    required Future<Uint8List> Function(String url) loadImage,
  }) {
    if (!started.isCompleted) started.complete();
    return answer.future;
  }
}

const lesson = Lesson(
  id: 'lesson',
  courseId: 'course',
  classroomId: 'classroom',
  title: '课堂',
  live: true,
);
const question = Question(
  id: 'question',
  body: '一加一等于几？',
  type: 1,
  options: {'A': '2', 'B': '3'},
);
const firstDeck = Presentation(
  id: 'first',
  title: '第一份课件',
  slides: [Slide(id: 'slide', index: 0, imageUrl: '', question: question)],
);
const secondDeck = Presentation(
  id: 'second',
  title: '第二份课件',
  slides: [Slide(id: 'second-slide', index: 0, imageUrl: '')],
);

AppController makeController(
  IsolationRain api,
  DelayedStore store, {
  AiAnswerService? ai,
}) => AppController(
  api: api,
  store: store,
  ai: ai,
  aiRequests: AiRequestScheduler(),
  background: NoBackground(),
  startTimers: false,
  connectSockets: false,
);

Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 50; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: '等待的异步状态未出现');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a late account A answer restore cannot contaminate account B',
    () async {
      final api = IsolationRain();
      final store = DelayedStore();
      final lateRead = Completer<String?>();
      final readStarted = Completer<void>();
      store.pendingReads['answers:a'] = lateRead;
      store.readsStarted['answers:a'] = readStarted;
      final controller = makeController(api, store);
      addTearDown(controller.dispose);

      final loginA = controller.loginCompleted();
      await readStarted.future.timeout(const Duration(seconds: 1));
      expect(controller.account?.id, 'a');
      await controller.logout();

      api.accountForProfile = const Account(id: 'b', name: 'B');
      await controller.loginCompleted();
      expect(controller.account?.id, 'b');
      expect(api.cookieExports, 1);

      lateRead.complete(
        jsonEncode({
          lesson.id: [
            {
              'problemId': question.id,
              'answer': ['A'],
              'score': 0,
            },
          ],
        }),
      );
      await loginA;

      final liveB = await controller.enter(lesson);
      expect(liveB.session.userId, 'b');
      expect(liveB.answers, isEmpty);
      expect(controller.account?.id, 'b');
      expect(api.cookieExports, 1, reason: '失效的 A 登录不应继续保存 Cookie');
      expect(store.values['answers:b'], isNull);
    },
  );

  for (final newDeckFails in [false, true]) {
    test(
      'sync includes a deck added during an earlier request '
      '(${newDeckFails ? 'new deck unavailable' : 'new deck available'})',
      () async {
        final api = IsolationRain()..userId = 'a';
        api.decks['second'] = secondDeck;
        final oldResult = Completer<Map<String, AnswerRecord>>();
        final newResult = Completer<Map<String, AnswerRecord>>();
        final oldStarted = Completer<void>();
        final newStarted = Completer<void>();
        api.answerResponses.addAll({'first': oldResult, 'second': newResult});
        api.answerReadsStarted.addAll({
          'first': oldStarted,
          'second': newStarted,
        });
        final controller = makeController(api, DelayedStore())
          ..account = api.accountForProfile;
        addTearDown(controller.dispose);
        final live = await controller.enter(lesson);
        live.presentations['first'] = firstDeck;
        live.presentationId = 'first';

        var completed = false;
        final syncing = controller.syncAnswers(live).whenComplete(() {
          completed = true;
        });
        await oldStarted.future.timeout(const Duration(seconds: 1));
        await controller.processEvent(live, {
          'op': 'showpresentation',
          'presentation': 'second',
          'slideindex': 1,
        });
        expect(live.presentationId, 'second');
        expect(live.answersKnown, isFalse);

        oldResult.complete({});
        await newStarted.future.timeout(const Duration(seconds: 1));
        expect(api.answerRequests, ['first', 'second']);
        expect(completed, isFalse);
        expect(live.syncingAnswers, isTrue);
        expect(live.answersKnown, isFalse, reason: '第一份课件返回不能证明新课件的本人答题状态');

        if (newDeckFails) {
          newResult.completeError(const ApiFailure('第二份课件读取失败'));
        } else {
          newResult.complete({});
        }
        await syncing;
        expect(live.syncingAnswers, isFalse);
        expect(live.answersKnown, !newDeckFails);
        if (newDeckFails) {
          expect(live.answerSyncError, contains('第二份课件读取失败'));
        }
      },
    );
  }

  test(
    'a finish event leaves the event queue while AI is still pending',
    () async {
      final api = IsolationRain()..userId = 'a';
      api.decks['first'] = firstDeck;
      final ai = WaitingAi();
      final controller = makeController(api, DelayedStore(), ai: ai)
        ..account = api.accountForProfile
        ..settings = AppSettings(
          autoAnswer: true,
          autoSubmit: true,
          answerMode: AnswerMode.ai,
          baseUrl: 'https://example.com/v1',
        );
      addTearDown(controller.dispose);
      final live = await controller.enter(lesson);
      Future<void> queue(Json event) => live.eventQueue = live.eventQueue.then(
        (_) => controller.processEvent(live, event),
      );

      try {
        await queue({'op': 'hello', 'presentation': 'first', 'slideindex': 1});
        await controller.syncAnswers(live);
        unawaited(
          queue({
            'op': 'unlockproblem',
            'problem': {
              'prob': question.id,
              'pres': 'first',
              'dt': DateTime.now().millisecondsSinceEpoch,
              'limit': 60,
            },
          }),
        );
        await ai.started.future.timeout(const Duration(seconds: 1));
        expect(ai.answer.isCompleted, isFalse);

        await queue({
          'op': 'lessonfinished',
        }).timeout(const Duration(seconds: 1));
        expect(live.ended, isTrue);
        expect(live.activeProblemIds, isEmpty);
        expect(live.connectionLabel, '课堂已结束');
        expect(ai.answer.isCompleted, isFalse, reason: '下课状态必须在 AI 请求完成前处理');
        expect(api.submissions, 0);

        ai.answer.complete('A');
        await Future<void>.delayed(Duration.zero);
        expect(controller.answerStatus(live, question), '作答已结束');
        expect(api.submissions, 0);
        expect(live.answers.containsKey(question.id), isFalse);
      } finally {
        if (!ai.answer.isCompleted) ai.answer.complete('A');
      }
    },
  );
}
