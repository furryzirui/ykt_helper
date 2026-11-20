import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/live_connection.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/background_runtime.dart';

DateTime automationTestNow() {
  try {
    return TestWidgetsFlutterBinding.instance.clock.now();
  } on AssertionError {
    return DateTime.now();
  }
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};
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

class NoAutostart extends AppAutostart {
  const NoAutostart();
  @override
  bool get supported => false;
}

class FakeRain extends RainApi {
  int checkins = 0, submissions = 0;
  int answerReads = 0;
  final submittedAnswers = <dynamic>[];
  final submittedIds = <String>[];
  final submittedTimes = <DateTime>[];
  DateTime Function()? clock;
  Completer<void>? pendingSubmit;
  bool failSubmit = false, failSync = false;
  final decks = <String, Presentation>{};
  Map<String, AnswerRecord> remote = {};
  Completer<Map<String, AnswerRecord>>? pendingAnswers;
  Completer<ClassroomSession>? pendingCheckin;
  Completer<Presentation>? pendingPresentation;
  AttendanceStatus attendanceValue = AttendanceStatus.unknown;
  bool failAttendance = false;
  Completer<AttendanceStatus>? pendingAttendance;
  @override
  Future<AttendanceStatus> attendance(Lesson lesson) async {
    if (failAttendance) throw const ApiFailure('test attendance unavailable');
    return pendingAttendance?.future ?? attendanceValue;
  }

  @override
  Future<ClassroomSession> checkin(String lessonId) async {
    checkins++;
    return pendingCheckin?.future ??
        ClassroomSession(
          userId: 'u',
          lessonId: lessonId,
          bearer: 'b-$lessonId',
          lessonToken: 't-$lessonId',
        );
  }

  @override
  Future<Presentation> presentation(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
    bool withAnswers = true,
  }) async => pendingPresentation?.future ?? decks[presentationId]!;
  @override
  Future<Map<String, AnswerRecord>> ownAnswers(
    String lessonId,
    String presentationId,
  ) async {
    answerReads++;
    if (failSync) throw const ApiFailure('test sync unavailable');
    return pendingAnswers?.future ?? remote;
  }

  @override
  Future<void> submit(
    ClassroomSession session,
    Question question,
    dynamic answer,
  ) async {
    submissions++;
    submittedAnswers.add(answer);
    submittedIds.add(question.id);
    submittedTimes.add(clock?.call() ?? DateTime.now());
    if (failSubmit) throw const ApiFailure('test response lost');
    await pendingSubmit?.future;
  }

  @override
  Future<void> logout() async {}
}

class DeferredAi extends AiAnswerService {
  final Completer<String> result = Completer();
  List<Slide>? received;
  @override
  Future<String> generate({
    required AppSettings settings,
    required Question question,
    required List<Slide> slides,
    required Future<Uint8List> Function(String url) loadImage,
  }) {
    received = slides;
    return result.future;
  }
}

class BatchAi extends AiAnswerService {
  final requests = <String, List<Completer<String>>>{};
  @override
  Future<String> generate({
    required AppSettings settings,
    required Question question,
    required List<Slide> slides,
    required Future<Uint8List> Function(String url) loadImage,
  }) {
    final result = Completer<String>();
    requests.putIfAbsent(question.id, () => []).add(result);
    return result.future;
  }
}

class TimingConnection extends LiveConnection {
  final List<String> requested = [];
  TimingConnection(super.session) : super(onEvent: (_) {}, onStatus: (_) {});
  @override
  bool requestProblemInfo(String id) {
    requested.add(id);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeRain api;
  late AppController controller;
  final disposedControllers = <AppController>{};
  void disposeController() {
    if (disposedControllers.add(controller)) controller.dispose();
  }

  const lesson = Lesson(
    id: 'l',
    courseId: 'c',
    classroomId: 'cl',
    title: '课堂',
    live: true,
  );
  const question = Question(
    id: 'q',
    body: '1 + 1?',
    type: 1,
    options: {'A': '2', 'B': '3', 'C': '4'},
  );
  Json hello([List<Json> timeline = const []]) => {
    'op': 'hello',
    'presentation': 'p',
    'slideindex': 1,
    'timeline': timeline,
  };
  Json unlock({int? dt, String id = 'q', String? deck}) => {
    'op': 'unlockproblem',
    'problem': {
      'prob': id,
      'limit': 60,
      'dt': dt ?? controller.now().millisecondsSinceEpoch,
      'pres': ?deck,
    },
  };
  setUp(() {
    api = FakeRain();
    api.decks['p'] = const Presentation(
      id: 'p',
      title: '课件',
      slides: [
        Slide(
          id: 's1',
          index: 0,
          imageUrl: 'https://example.com/one.png',
          question: question,
        ),
        Slide(id: 's2', index: 1, imageUrl: 'https://example.com/two.png'),
      ],
    );
    controller = AppController(
      api: api,
      store: MemoryStore(),
      background: NoBackground(),
      autostart: const NoAutostart(),
      startTimers: false,
      now: automationTestNow,
      connectSockets: false,
    );
    controller.account = const Account(id: 'u', name: '测试');
  });
  tearDown(() => disposeController());
  void resetForWidgetTest() {
    addTearDown(disposeController);
    // Create Future chains inside the widget test's fake async zone.
    disposeController();
    controller = AppController(
      api: api,
      store: MemoryStore(),
      background: NoBackground(),
      autostart: const NoAutostart(),
      startTimers: false,
      now: automationTestNow,
      connectSockets: false,
    )..account = const Account(id: 'u', name: '测试');
  }

  void useAiClock(WidgetTester tester, BatchAi ai) {
    addTearDown(disposeController);
    disposeController();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
            connectSockets: false,
            now: tester.binding.clock.now,
          )
          ..account = const Account(id: 'u', name: '测试')
          ..settings = AppSettings(
            autoAnswer: true,
            autoSubmit: true,
            answerMode: AnswerMode.ai,
          );
    api.clock = tester.binding.clock.now;
  }

  Future<LiveClass> prepareBatch(
    WidgetTester tester,
    BatchAi ai, {
    int delay = 5,
  }) async {
    useAiClock(tester, ai);
    controller.settings.autoSubmitDelaySeconds = delay;
    api.decks['p'] = const Presentation(
      id: 'p',
      title: '批量',
      slides: [
        Slide(id: 's1', index: 0, imageUrl: '', question: question),
        Slide(
          id: 's2',
          index: 1,
          imageUrl: '',
          question: Question(
            id: 'q2',
            body: '第二题',
            type: 1,
            options: {'A': '甲', 'B': '乙', 'C': '丙'},
          ),
        ),
      ],
    );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    return live;
  }

  Future<void> openBatch(WidgetTester tester, LiveClass live) async {
    final dt = tester.binding.clock.now().millisecondsSinceEpoch;
    for (final id in ['q2', 'q']) {
      await controller.processEvent(live, unlock(id: id, dt: dt));
    }
    await tester.pump();
  }

  testWidgets(
    'same-batch page order waits for the first success then spaces the next',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai);
      ai.requests['q']!.single.complete('A');
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      await openBatch(tester, live);
      final pending = Completer<void>();
      api.pendingSubmit = pending;
      await tester.pump(const Duration(seconds: 5));
      expect(api.submittedIds, ['q']);
      await tester.pump(const Duration(seconds: 7));
      expect(api.submittedIds, ['q']);
      api.pendingSubmit = null;
      pending.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(api.submittedIds, ['q']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submittedIds, ['q', 'q2']);
      expect(
        api.submittedTimes[1].difference(api.submittedTimes[0]),
        const Duration(seconds: 12),
      );
    },
  );

  testWidgets(
    'manual submissions bypass the queue and space pending automatic work',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai);
      ai.requests['q']!.single.complete('A');
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      await openBatch(tester, live);
      final pending = Completer<void>();
      api.pendingSubmit = pending;
      final manual = controller.submitAnswer(live, live.questions['q2']!, [
        'C',
      ]);
      await tester.pump(const Duration(seconds: 8));
      expect(api.submittedIds, ['q2']);
      api.pendingSubmit = null;
      pending.complete();
      await manual;
      await tester.pump(const Duration(seconds: 4));
      expect(api.submittedIds, ['q2']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submittedIds, ['q2', 'q']);
      expect(live.autoStates['q2'], '答案已提交');
    },
  );

  testWidgets(
    'manual submission remains available while automatic status is unknown',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai);
      ai.requests['q']!.single.complete('A');
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      await openBatch(tester, live);
      api.failSubmit = true;
      await expectLater(
        controller.submitAnswer(live, live.questions['q']!, ['A']),
        throwsA(isA<ApiFailure>()),
      );
      expect(live.answersKnown, isFalse);
      expect(controller.canSubmitAnswer(live, live.questions['q2']!), isTrue);
      api.failSubmit = false;
      await controller.submitAnswer(live, live.questions['q2']!, ['C']);
      expect(live.autoStates['q2'], '答案已提交');
      expect(api.submittedIds, ['q', 'q2']);
    },
  );

  testWidgets(
    'manual success during an automatic prelookup postpones that automatic POST',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai);
      ai.requests['q']!.single.complete('A');
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      await openBatch(tester, live);
      api.pendingAnswers = Completer();
      await tester.pump(const Duration(seconds: 5));
      expect(api.submissions, 0);
      await controller.submitAnswer(live, live.questions['q2']!, ['C']);
      api.pendingAnswers!.complete({});
      api.pendingAnswers = null;
      await tester.pump();
      expect(api.submittedIds, ['q2']);
      await tester.pump(const Duration(seconds: 4));
      expect(api.submittedIds, ['q2']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submittedIds, ['q2', 'q']);
    },
  );

  testWidgets(
    'head AI is awaited and an explicit AI failure skips to the next question',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai);
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      await openBatch(tester, live);
      await tester.pump(const Duration(seconds: 8));
      expect(api.submissions, 0);
      ai.requests['q']!.single.completeError(
        const ApiFailure('provider unavailable'),
      );
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(api.submittedIds, ['q2']);
      expect(live.autoStates['q'], contains('provider unavailable'));
    },
  );

  testWidgets(
    'an expired head with pending AI immediately releases the next ready question',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai, delay: 2);
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      final dt = controller.now().millisecondsSinceEpoch;
      await controller.processEvent(live, {
        'op': 'unlockproblem',
        'problem': {'prob': 'q', 'dt': dt, 'limit': 4},
      });
      await controller.processEvent(live, unlock(id: 'q2', dt: dt));
      await tester.pump(const Duration(seconds: 3));
      expect(api.submissions, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submittedIds, ['q2']);
      expect(live.autoStates['q'], '作答已结束');
      ai.requests['q']!.single.complete('A');
      await tester.pump();
      expect(api.submittedIds, ['q2']);
    },
  );

  testWidgets(
    'remote newly observed submissions space work without extending on repeated reads',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai);
      ai.requests['q']!.single.complete('A');
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      await openBatch(tester, live);
      await tester.pump(const Duration(seconds: 2));
      api.remote = {
        'q': const AnswerRecord(
          problemId: 'q',
          answer: ['C'],
          source: AnswerSource.server,
        ),
      };
      await controller.syncAnswers(live);
      await tester.pump(const Duration(seconds: 3));
      await controller.syncAnswers(live);
      expect(api.submissions, 0);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(api.submittedIds, ['q2']);
    },
  );

  testWidgets(
    'uncertain POST pauses the classroom and sync never blindly retries the failed round',
    (tester) async {
      final ai = BatchAi();
      final live = await prepareBatch(tester, ai);
      ai.requests['q']!.single.complete('A');
      ai.requests['q2']!.single.complete('B');
      await tester.pump();
      await openBatch(tester, live);
      api.failSubmit = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(api.submittedIds, ['q']);
      await tester.pump(const Duration(seconds: 5));
      expect(api.submittedIds, ['q']);
      api.failSubmit = false;
      await controller.syncAnswers(live);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(api.submittedIds, ['q', 'q2']);
      await controller.processEvent(
        live,
        unlock(id: 'q', dt: live.questions['q']!.dt),
      );
      await tester.pump(const Duration(seconds: 6));
      expect(api.submittedIds, ['q', 'q2']);
    },
  );

  testWidgets(
    'loaded questions start AI independently before timing or answer sync',
    (tester) async {
      final ai = BatchAi();
      useAiClock(tester, ai);
      api.decks['p'] = const Presentation(
        id: 'p',
        title: '课件',
        slides: [
          Slide(id: 's1', index: 0, imageUrl: '', question: question),
          Slide(
            id: 's2',
            index: 1,
            imageUrl: '',
            question: Question(
              id: 'q2',
              body: '另一道题',
              type: 1,
              options: {'A': '甲', 'B': '乙', 'C': '丙'},
            ),
          ),
        ],
      );
      api.pendingAnswers = Completer();
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await tester.pump();
      expect(ai.requests.keys, containsAll(['q', 'q2']));
      expect(live.answersKnown, isFalse);
      ai.requests['q']!.single.complete('A');
      ai.requests['q2']!.single.complete('C');
      await tester.pump();
      expect(live.draftAnswers['q'], ['A']);
      expect(live.draftAnswers['q2'], ['C']);
      expect(controller.canEditAnswer(live, live.questions['q']!), isTrue);
      expect(controller.canSubmitAnswer(live, live.questions['q']!), isFalse);
      await expectLater(
        controller.submitAnswer(live, live.questions['q']!, ['A']),
        throwsA(isA<ApiFailure>()),
      );
      controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
      await controller.processEvent(live, hello());
      expect(ai.requests['q'], hasLength(1));
      expect(ai.requests['q2'], hasLength(1));
      api.pendingAnswers!.complete({});
      api.pendingAnswers = null;
      await controller.syncAnswers(live);
      await controller.processEvent(
        live,
        unlock(dt: tester.binding.clock.now().millisecondsSinceEpoch),
      );
      await tester.pump();
      expect(live.draftAnswers['q'], ['B']);
      await tester.pump(const Duration(seconds: 29));
      expect(api.submissions, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submittedAnswers, [
        ['B'],
      ]);
      expect(controller.answerStatus(live, live.questions['q']!), '答案已提交');
    },
  );

  testWidgets('slow AI uses the remaining delay from answerability', (
    tester,
  ) async {
    final ai = BatchAi();
    useAiClock(tester, ai);
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(
      live,
      unlock(dt: tester.binding.clock.now().millisecondsSinceEpoch),
    );
    await tester.pump(const Duration(seconds: 20));
    ai.requests['q']!.single.complete('A');
    await tester.pump();
    expect(live.autoStates['q'], '答案已填充，10 秒后自动提交');
    await tester.pump(const Duration(seconds: 9));
    expect(api.submissions, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(api.submissions, 1);
  });

  testWidgets(
    'late timing uses publication time and server offset instead of restarting delay',
    (tester) async {
      final ai = BatchAi();
      useAiClock(tester, ai);
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      ai.requests['q']!.single.complete('A');
      await tester.pump();
      await controller.syncAnswers(live);
      final localNow = controller.now().millisecondsSinceEpoch;
      const offset = 5000;
      await controller.processEvent(live, {
        'op': 'unlockproblem',
        'problem': {
          'prob': 'q',
          'dt': localNow + offset - 20000,
          'now': localNow + offset,
          'limit': 120,
        },
      });
      await tester.pump();
      expect(live.autoStates['q'], '答案已填充，10 秒后自动提交');
      await tester.pump(const Duration(seconds: 9));
      expect(api.submissions, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submittedIds, ['q']);
    },
  );

  testWidgets(
    'explicit future timing cannot submit early and opens without another event',
    (tester) async {
      final ai = BatchAi();
      useAiClock(tester, ai);
      controller.settings.autoSubmitDelaySeconds = 5;
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      ai.requests['q']!.single.complete('A');
      await tester.pump();
      await controller.syncAnswers(live);
      final startsAt = tester.binding.clock.now().add(
        const Duration(seconds: 10),
      );
      await controller.processEvent(
        live,
        unlock(dt: startsAt.millisecondsSinceEpoch),
      );
      expect(controller.canSubmitAnswer(live, live.questions['q']!), isFalse);
      expect(controller.canEditAnswer(live, live.questions['q']!), isTrue);
      await tester.pump(const Duration(seconds: 9));
      expect(api.submissions, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.canSubmitAnswer(live, live.questions['q']!), isTrue);
      await tester.pump(const Duration(seconds: 4));
      expect(api.submissions, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submissions, 1);
    },
  );

  test(
    'missing launch limit stays unconfirmed until explicit server timing arrives',
    () async {
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      final dt = DateTime.now().millisecondsSinceEpoch;
      await controller.processEvent(live, {
        'op': 'unlockproblem',
        'problem': {'prob': 'q', 'dt': dt},
      });
      expect(controller.answerStatus(live, live.questions['q']!), '正在确认作答时间');
      expect(controller.canSubmitAnswer(live, live.questions['q']!), isFalse);
      expect(controller.canEditAnswer(live, live.questions['q']!), isTrue);
      await controller.processEvent(live, {
        'op': 'probleminfo',
        'problemid': 'q',
        'dt': dt,
        'limit': 60,
      });
      expect(controller.canSubmitAnswer(live, live.questions['q']!), isTrue);
      expect(controller.answerStatus(live, live.questions['q']!), '可以作答');
      await controller.processEvent(live, {
        'op': 'probleminfo',
        'problemid': 'q',
        'dt': dt,
        'limit': 0,
      });
      expect(controller.answerStatus(live, live.questions['q']!), '作答已结束');
    },
  );

  testWidgets(
    'editing after launch submits latest draft at the original deadline',
    (tester) async {
      final ai = BatchAi();
      useAiClock(tester, ai);
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      ai.requests['q']!.single.complete('A');
      await tester.pump();
      await controller.syncAnswers(live);
      await controller.processEvent(
        live,
        unlock(dt: tester.binding.clock.now().millisecondsSinceEpoch),
      );
      await tester.pump(const Duration(seconds: 20));
      controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
      await tester.pump(const Duration(seconds: 9));
      expect(api.submissions, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submittedAnswers, [
        ['B'],
      ]);
    },
  );

  testWidgets(
    'cleared draft never submits and completing it uses the elapsed delay',
    (tester) async {
      final ai = BatchAi();
      useAiClock(tester, ai);
      controller.settings.autoSubmitDelaySeconds = 5;
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      ai.requests['q']!.single.complete('A');
      await tester.pump();
      await controller.syncAnswers(live);
      await controller.processEvent(
        live,
        unlock(dt: tester.binding.clock.now().millisecondsSinceEpoch),
      );
      controller.updateAnswerDraft(live, live.questions['q']!, <String>[]);
      expect(live.autoStates['q'], contains('请选择答案'));
      await tester.pump(const Duration(seconds: 8));
      expect(api.submissions, 0);
      controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
      expect(live.autoStates['q'], '答案已填充，0 秒后自动提交');
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(api.submittedAnswers, [
        ['B'],
      ]);
    },
  );

  testWidgets(
    'refresh preserves authoritative timing and cached AI until content changes',
    (tester) async {
      final ai = BatchAi();
      useAiClock(tester, ai);
      controller.settings.autoSubmit = false;
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      ai.requests['q']!.single.complete('A');
      await tester.pump();
      await controller.syncAnswers(live);
      final localTime = tester.binding.clock.now().millisecondsSinceEpoch;
      await controller.processEvent(live, {
        'op': 'unlockproblem',
        'problem': {
          'prob': 'q',
          'dt': localTime + 5000,
          'now': localTime + 5000,
          'limit': 60,
        },
      });
      final authoritative = live.questions['q']!;
      await controller.refreshClassroom(live);
      await tester.pump();
      expect(identical(live.questions['q'], authoritative), isTrue);
      expect(ai.requests['q'], hasLength(1));
      await tester.pump(const Duration(seconds: 61));
      expect(live.activeProblemIds, isNot(contains('q')));
      expect(live.autoStates['q'], '作答已结束');

      // An actual changed PPT question invalidates a cached draft even if its
      // protocol ID is unchanged; old provider work cannot overwrite the new one.
      await controller.processEvent(
        live,
        unlock(dt: tester.binding.clock.now().millisecondsSinceEpoch),
      );
      api.decks['p'] = const Presentation(
        id: 'p',
        title: '更新',
        slides: [
          Slide(
            id: 's1',
            index: 0,
            imageUrl: '',
            question: Question(
              id: 'q',
              body: '改过的题干',
              type: 1,
              options: {'A': '甲', 'B': '乙', 'C': '丙'},
            ),
          ),
        ],
      );
      await controller.refreshClassroom(live);
      expect(ai.requests['q'], hasLength(3));
      ai.requests['q']![1].complete('A');
      ai.requests['q']![2].complete('C');
      await tester.pump();
      expect(live.draftAnswers['q'], ['C']);
    },
  );

  test(
    'terminal status overrides stale automation labels with no queued job',
    () async {
      var clock = DateTime.now();
      disposeController();
      controller = AppController(
        api: api,
        store: MemoryStore(),
        background: NoBackground(),
        autostart: const NoAutostart(),
        startTimers: false,
        connectSockets: false,
        now: () => clock,
      )..account = const Account(id: 'u', name: '测试');
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.syncAnswers(live);
      await controller.processEvent(
        live,
        unlock(dt: clock.millisecondsSinceEpoch),
      );
      live.autoStates['q'] = '答案已填充，待确认提交';
      clock = clock.add(const Duration(seconds: 61));
      expect(controller.answerStatus(live, live.questions['q']!), '作答已结束');
      expect(controller.canEditAnswer(live, live.questions['q']!), isFalse);
      expect(controller.canSubmitAnswer(live, live.questions['q']!), isFalse);
      api.remote = {
        'q': const AnswerRecord(
          problemId: 'q',
          answer: ['B'],
          source: AnswerSource.server,
        ),
      };
      await Future<void>.delayed(Duration.zero);
      await controller.syncAnswers(live);
      expect(live.autoStates['q'], '答案已提交');
      await controller.processEvent(live, {
        'op': 'problemfinished',
        'prob': 'q',
      });
      expect(controller.answerStatus(live, live.questions['q']!), '答案已提交');
    },
  );

  test(
    'a presentation fetched before suspension cannot restore stale state',
    () async {
      final live = await controller.enter(lesson);
      final pending = Completer<Presentation>();
      api.pendingPresentation = pending;
      final oldHello = controller.processEvent(live, hello());
      await Future<void>.delayed(Duration.zero);

      controller.setForeground(false);
      controller.setForeground(true);
      api.pendingPresentation = null;
      pending.complete(api.decks['p']!);
      await oldHello;

      expect(live.presentations, isEmpty);
      expect(live.presentationId, isNull);
      expect(live.activeProblemIds, isEmpty);
      await controller.processEvent(live, hello());
      expect(live.presentationId, 'p');
    },
  );

  test(
    'an unlock fetched before suspension cannot reactivate an old question',
    () async {
      final live = await controller.enter(lesson);
      final pending = Completer<Presentation>();
      api.pendingPresentation = pending;
      final oldUnlock = controller.processEvent(live, unlock(deck: 'p'));
      await Future<void>.delayed(Duration.zero);

      controller.setForeground(false);
      controller.setForeground(true);
      api.pendingPresentation = null;
      pending.complete(api.decks['p']!);
      await oldUnlock;

      expect(live.activeProblemIds, isEmpty);
      expect(live.launches, isEmpty);
      expect(live.questions, isEmpty);
      await controller.processEvent(live, hello());
      await controller.processEvent(live, unlock());
      expect(live.activeProblemIds, contains('q'));
    },
  );

  test(
    'automatic answers only fill a draft until confirmed by default',
    () async {
      controller.settings = AppSettings(autoAnswer: true, fixedAnswer: 'A');
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.syncAnswers(live);
      await controller.processEvent(live, unlock());
      await Future<void>.delayed(Duration.zero);
      expect(api.submissions, 0);
      expect(live.answers, isEmpty);
      expect(live.draftAnswers['q'], ['A']);
      expect(live.autoStates['q'], '答案已填充，待确认提交');
      await controller.processEvent(live, unlock(dt: live.questions['q']!.dt));
      expect(api.submissions, 0);
      await controller.submitAnswer(live, live.questions['q']!, ['B']);
      expect(api.submissions, 1);
      expect(live.answers['q']!.answer, ['B']);
      expect(live.draftAnswers, isEmpty);
    },
  );
  for (final type in [1, 2, 3, 4, 5, 6]) {
    test('fixed answer category is used for protocol type $type', () async {
      controller.settings = AppSettings(
        autoAnswer: true,
        fixedSingleAnswer: 'B',
        fixedMultipleAnswer: 'AB',
        fixedSubjectiveAnswer: '第一空;第二空',
      );
      api.decks['p'] = Presentation(
        id: 'p',
        title: '分类答案',
        slides: [
          Slide(
            id: 's1',
            index: 0,
            imageUrl: '',
            question: Question(
              id: 'q',
              body: '题目',
              type: type,
              options: const {'A': '甲', 'B': '乙', 'C': '丙'},
              selectionLimit: 2,
              blankCount: 2,
            ),
          ),
        ],
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.syncAnswers(live);
      await controller.processEvent(live, unlock());
      await Future<void>.delayed(Duration.zero);
      final dynamic expected = switch (type) {
        1 => ['B'],
        6 => ['A'],
        2 || 3 => ['A', 'B'],
        4 => ['第一空;第二空', '第一空;第二空'],
        _ => {'content': '第一空;第二空', 'pics': [], 'videos': []},
      };
      expect(live.draftAnswers['q'], expected);
      expect(live.autoStates['q'], '答案已填充，待确认提交');
      expect(api.submissions, 0);
    });
  }

  test(
    'fixed fill-in repeats the complete text in every blank without splitting lines or punctuation',
    () async {
      const content = '同一段内容\n第二行；保留分号;和标点';
      controller.settings = AppSettings(
        autoAnswer: true,
        fixedSubjectiveAnswer: content,
      );
      const question = Question(id: 'q', body: '三个空', type: 4, blankCount: 3);
      api.decks['p'] = const Presentation(
        id: 'p',
        title: '固定填空',
        slides: [Slide(id: 's1', index: 0, imageUrl: '', question: question)],
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.syncAnswers(live);
      await controller.processEvent(live, unlock());
      await Future<void>.delayed(Duration.zero);
      expect(live.draftAnswers['q'], [content, content, content]);
      expect(api.submissions, 0);
      await controller.submitAnswer(
        live,
        live.questions['q']!,
        live.draftAnswers['q'],
      );
      expect(api.submittedAnswers.single, [content, content, content]);
    },
  );

  for (final type in [1, 2, 3]) {
    test(
      'two options use the judgment fixed answer for protocol $type',
      () async {
        controller.settings = AppSettings(
          autoAnswer: true,
          fixedSingleAnswer: 'D',
          fixedMultipleAnswer: 'AC',
          fixedJudgmentAnswer: 'B',
        );
        api.decks['p'] = Presentation(
          id: 'p',
          title: '两选项',
          slides: [
            Slide(
              id: 's1',
              index: 0,
              imageUrl: '',
              question: Question(
                id: 'q',
                body: '两选项',
                type: type,
                selectionLimit: 2,
                options: const {'A': '甲', 'B': '乙'},
              ),
            ),
          ],
        );
        final live = await controller.enter(lesson);
        await controller.processEvent(live, hello());
        await controller.syncAnswers(live);
        await controller.processEvent(live, unlock());
        await Future<void>.delayed(Duration.zero);
        expect(live.draftAnswers['q'], ['B']);
        expect(live.autoStates['q'], '答案已填充，待确认提交');
        expect(api.submissions, 0);
      },
    );
  }

  test('empty fixed category skips without borrowing another answer', () async {
    controller.settings = AppSettings(
      autoAnswer: true,
      fixedSingleAnswer: '',
      fixedMultipleAnswer: 'AB',
      fixedSubjectiveAnswer: '文字答案',
    );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(live, unlock());
    await Future<void>.delayed(Duration.zero);
    expect(live.draftAnswers, isEmpty);
    expect(live.autoStates['q'], '未设置此题型固定答案，已跳过');
    expect(api.submissions, 0);
  });

  test('saving fixed automation retains missing answer categories', () async {
    controller.account = null;
    for (final missing in ['single', 'multiple', 'judgment', 'subjective']) {
      final settings = AppSettings(
        autoAnswer: true,
        fixedSingleAnswer: missing == 'single' ? ' ' : 'A',
        fixedMultipleAnswer: missing == 'multiple' ? '' : 'AB',
        fixedJudgmentAnswer: missing == 'judgment' ? '' : 'A',
        fixedSubjectiveAnswer: missing == 'subjective' ? '\n' : '文字答案',
      );
      await controller.saveSettings(settings);
      expect(controller.settings.toJson(), settings.toJson());
    }
    await controller.saveSettings(
      AppSettings(
        autoAnswer: true,
        fixedSingleAnswer: 'A',
        fixedMultipleAnswer: 'AB',
        fixedSubjectiveAnswer: '文字答案',
      ),
    );
    expect(controller.settings.autoAnswer, true);
    expect(controller.settings.fixedMultipleAnswer, 'AB');
  });

  test(
    'ambiguous single-choice fixed answer still fails strict parsing',
    () async {
      controller.settings = AppSettings(
        autoAnswer: true,
        fixedSingleAnswer: 'AB',
        fixedMultipleAnswer: 'A',
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.syncAnswers(live);
      await controller.processEvent(live, unlock());
      await Future<void>.delayed(Duration.zero);
      expect(live.draftAnswers, isEmpty);
      expect(live.autoStates['q'], contains('答案无法明确匹配选项'));
      expect(api.submissions, 0);
    },
  );

  test('AI answers also remain drafts when auto submit is off', () async {
    final ai = DeferredAi();
    disposeController();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
            now: automationTestNow,
            connectSockets: false,
          )
          ..account = const Account(id: 'u', name: '测试')
          ..settings = AppSettings(
            autoAnswer: true,
            answerMode: AnswerMode.ai,
            baseUrl: 'https://ai.example/v1',
            model: 'model',
          );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(live, unlock());
    ai.result.complete('A');
    await Future<void>.delayed(Duration.zero);
    expect(api.submissions, 0);
    expect(live.draftAnswers['q'], ['A']);
  });
  test('late AI cannot fill a closed question or changed settings', () async {
    final ai = DeferredAi();
    disposeController();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
            now: automationTestNow,
            connectSockets: false,
          )
          ..account = const Account(id: 'u', name: '测试')
          ..settings = AppSettings(
            autoAnswer: true,
            answerMode: AnswerMode.ai,
            baseUrl: 'https://ai.example/v1',
            model: 'model',
          );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(live, unlock());
    await controller.processEvent(live, {'op': 'problemfinished', 'prob': 'q'});
    ai.result.complete('A');
    await Future<void>.delayed(Duration.zero);
    expect(api.submissions, 0);
    expect(live.draftAnswers, isEmpty);
  });
  test(
    'attendance is remote evidence and resets to unknown on read failure',
    () async {
      api.attendanceValue = AttendanceStatus.signed;
      final live = await controller.enter(lesson);
      await Future<void>.delayed(Duration.zero);
      expect(live.checkinText, '已签到');
      api.failAttendance = true;
      await controller.syncAttendance(live);
      expect(live.attendance, AttendanceStatus.unknown);
      expect(live.attendanceError, isNotNull);
      expect(live.location, isNull);
    },
  );
  test('attendance arriving after logout is ignored', () async {
    final pending = Completer<AttendanceStatus>();
    api.pendingAttendance = pending;
    final live = await controller.enter(lesson);
    await controller.logout();
    pending.complete(AttendanceStatus.signed);
    await Future<void>.delayed(Duration.zero);
    expect(live.attendance, AttendanceStatus.unknown);
    expect(controller.classrooms, isEmpty);
  });
  test(
    'unlimited questions stay open until the teacher closes that exact problem',
    () async {
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.processEvent(live, {
        'op': 'unlockproblem',
        'problem': {'prob': 'q', 'dt': 1, 'limit': -1},
      });
      expect(live.activeProblemIds, contains('q'));
      await controller.submitAnswer(live, live.questions['q']!, ['A']);
      expect(api.submissions, 1);
      await controller.processEvent(live, {
        'op': 'problemfinished',
        'prob': 'q',
      });
      expect(live.activeProblemIds, isNot(contains('q')));
      await controller.processEvent(
        live,
        hello([
          {'type': 'problem', 'prob': 'q', 'pres': 'p', 'dt': 1, 'limit': -1},
        ]),
      );
      expect(live.activeProblemIds, isNot(contains('q')));
    },
  );
  test(
    'extension is authoritative and repeated messages never add time twice',
    () async {
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      final dt = DateTime.now().millisecondsSinceEpoch;
      await controller.processEvent(live, unlock(dt: dt));
      final extend = {
        'op': 'extendtime',
        'problem': {
          'prob': 'q',
          'extend': 30,
          'limit': 90,
          'dt': dt,
          'now': dt,
        },
      };
      await controller.processEvent(live, extend);
      await controller.processEvent(live, extend);
      expect(live.questions['q']!.limit, 90);
      await controller.processEvent(live, {
        'op': 'extendtime',
        'problem': {'extend': 30, 'limit': 120},
      });
      expect(live.questions['q']!.limit, 90);
      expect(live.error, contains('未能关联'));
    },
  );
  test(
    'timeline questions wait for server timing before becoming answerable',
    () async {
      disposeController();
      controller = AppController(
        api: api,
        store: MemoryStore(),
        background: NoBackground(),
        autostart: const NoAutostart(),
        startTimers: false,
        now: automationTestNow,
        connectSockets: true,
      )..account = const Account(id: 'u', name: '测试');
      final live = LiveClass(
        lesson: lesson,
        session: const ClassroomSession(
          userId: 'u',
          lessonId: 'l',
          bearer: 'b',
          lessonToken: 't',
        ),
      );
      final connection = TimingConnection(live.session);
      live.connection = connection;
      controller.classrooms['l'] = live;
      final now = DateTime.now().millisecondsSinceEpoch;
      await controller.processEvent(
        live,
        hello([
          {'type': 'problem', 'prob': 'q', 'pres': 'p', 'dt': now, 'limit': 60},
        ]),
      );
      expect(connection.requested, ['q']);
      expect(live.activeProblemIds, isEmpty);
      await controller.processEvent(live, {
        'op': 'probleminfo',
        'problemid': 'q',
        'dt': now,
        'now': now,
        'limit': 60,
      });
      expect(live.activeProblemIds, contains('q'));
      await controller.processEvent(live, {
        'op': 'probleminfo',
        'problemid': 'q',
        'dt': now,
        'now': now,
        'limit': 0,
      });
      expect(live.activeProblemIds, isEmpty);
    },
  );
  test('teacher presentation updates replace cached questions', () async {
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    api.decks['p'] = const Presentation(
      id: 'p',
      title: '更新',
      slides: [
        Slide(
          id: 'new',
          index: 0,
          imageUrl: '',
          question: Question(id: 'q2', body: '新增题目', type: 5),
        ),
      ],
    );
    await controller.processEvent(live, {
      'op': 'presentationupdated',
      'presentation': 'p',
    });
    expect(live.currentQuestion!.id, 'q2');
    expect(live.questions.containsKey('q'), false);
  });
  test(
    'concurrent entry deduplicates checkin and isolates lesson credentials',
    () async {
      final results = await Future.wait([
        controller.enter(lesson),
        controller.enter(lesson),
      ]);
      expect(api.checkins, 1);
      expect(identical(results[0], results[1]), true);
      final other = await controller.enter(
        const Lesson(
          id: 'l2',
          courseId: 'c',
          classroomId: 'cl2',
          title: '课堂2',
          live: true,
        ),
      );
      expect(other.session.bearer, 'b-l2');
      expect(results[0].session.bearer, 'b-l');
    },
  );
  testWidgets(
    'duplicate unlock cannot submit twice and the submitted answer survives sync',
    (tester) async {
      resetForWidgetTest();
      controller.settings = AppSettings(
        autoAnswer: true,
        autoSubmit: true,
        fixedAnswer: 'A',
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      final event = unlock();
      await controller.processEvent(live, event);
      await controller.processEvent(live, event);
      await controller.syncAnswers(live);
      await tester.pump(const Duration(seconds: 29));
      expect(api.submissions, 0);
      expect(live.draftAnswers['q'], ['A']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.submissions, 1);
      expect(live.answers['q']!.answer, ['A']);
    },
  );
  test(
    'a zero-score server submission is preserved and never answered automatically',
    () async {
      api.remote = {
        'q': const AnswerRecord(
          problemId: 'q',
          answer: ['B'],
          source: AnswerSource.server,
          score: 0,
        ),
      };
      controller.settings = AppSettings(
        autoAnswer: true,
        autoSubmit: true,
        fixedAnswer: 'A',
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.processEvent(live, unlock());
      expect(api.submissions, 0);
      expect(live.answers['q']!.display, 'B');
    },
  );
  test(
    'expired questions and unknown remote states do not trigger automation',
    () async {
      controller.settings = AppSettings(
        autoAnswer: true,
        autoSubmit: true,
        fixedAnswer: 'A',
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.processEvent(
        live,
        unlock(dt: DateTime.now().millisecondsSinceEpoch - 90000),
      );
      expect(api.submissions, 0);
      api.failSync = true;
      await controller.processEvent(live, unlock());
      await controller.syncAnswers(live);
      expect(live.answersKnown, false);
      expect(api.submissions, 0);
    },
  );
  testWidgets(
    'a lost submit response is not blindly repeated on another event',
    (tester) async {
      resetForWidgetTest();
      controller.settings = AppSettings(
        autoAnswer: true,
        autoSubmit: true,
        fixedAnswer: 'A',
      );
      api.failSubmit = true;
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      final event = unlock();
      await controller.processEvent(live, event);
      await controller.processEvent(live, event);
      await controller.syncAnswers(live);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(live.answerSyncError, contains('提交结果未确认'));
      expect(live.autoStates['q'], contains('自动答题未完成'));
      await controller.processEvent(live, event);
      await tester.pump(const Duration(seconds: 30));
      expect(api.submissions, 1);
      expect(live.answers.containsKey('q'), false);
    },
  );
  test('missing stored delay defaults while explicit values are retained', () {
    expect(AppSettings().autoSubmitDelaySeconds, 30);
    expect(AppSettings.fromJson({}).autoSubmitDelaySeconds, 30);
    expect(
      AppSettings.fromJson({
        'autoSubmitDelaySeconds': 0,
      }).autoSubmitDelaySeconds,
      0,
    );
    final restored = AppSettings.fromJson(
      AppSettings(autoSubmitDelaySeconds: 47).toJson(),
    );
    expect(restored.autoSubmitDelaySeconds, 47);
  });

  test(
    'saving an invalid automatic submission delay retains its value',
    () async {
      await controller.saveSettings(
        AppSettings(
          autoAnswer: true,
          autoSubmit: true,
          fixedAnswer: 'A',
          autoSubmitDelaySeconds: 0,
        ),
      );
      expect(controller.settings.autoSubmitDelaySeconds, 0);
    },
  );

  Future<LiveClass> prepareDelayed(
    WidgetTester tester, {
    int delay = 30,
  }) async {
    resetForWidgetTest();
    controller.settings = AppSettings(
      autoAnswer: true,
      autoSubmit: true,
      fixedAnswer: 'A',
      autoSubmitDelaySeconds: delay,
    );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(live, unlock());
    await tester.pump();
    return live;
  }

  testWidgets('custom delay waits fully and does not block another classroom', (
    tester,
  ) async {
    final first = await prepareDelayed(tester, delay: 12);
    final other = await controller.enter(
      const Lesson(
        id: 'l2',
        courseId: 'c',
        classroomId: 'cl2',
        title: '其他课堂',
        live: true,
      ),
    );
    await controller.processEvent(other, hello());
    await controller.syncAnswers(other);
    await controller.processEvent(other, unlock());
    await tester.pump();
    expect(first.autoStates['q'], '答案已填充，12 秒后自动提交');
    expect(other.draftAnswers['q'], ['A']);
    await tester.pump(const Duration(seconds: 11));
    expect(api.submissions, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(api.submissions, 2);
  });

  testWidgets('closing the question or lesson cancels delayed submission', (
    tester,
  ) async {
    final live = await prepareDelayed(tester);
    await controller.processEvent(live, {'op': 'problemfinished', 'prob': 'q'});
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 0);
    final other = await controller.enter(
      const Lesson(
        id: 'l2',
        courseId: 'c',
        classroomId: 'cl2',
        title: '其他课堂',
        live: true,
      ),
    );
    await controller.processEvent(other, hello());
    await controller.syncAnswers(other);
    await controller.processEvent(other, unlock());
    await tester.pump();
    await controller.processEvent(other, {'op': 'lessonfinished'});
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 0);
  });

  testWidgets('disabling automation and logout invalidate queued submissions', (
    tester,
  ) async {
    final live = await prepareDelayed(tester);
    await controller.saveSettings(
      AppSettings(autoAnswer: true, fixedAnswer: 'A'),
    );
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 0);
    expect(live.draftAnswers['q'], ['A']);
    controller.settings = AppSettings(
      autoAnswer: true,
      autoSubmit: true,
      fixedAnswer: 'A',
    );
    await controller.processEvent(
      live,
      unlock(dt: DateTime.now().millisecondsSinceEpoch + 1),
    );
    await tester.pump();
    await controller.logout();
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 0);
    expect(controller.classrooms, isEmpty);
  });

  testWidgets('remote answers are checked again after the delay', (
    tester,
  ) async {
    final live = await prepareDelayed(tester);
    final reads = api.answerReads;
    api.remote = {
      'q': const AnswerRecord(
        problemId: 'q',
        answer: ['B'],
        source: AnswerSource.server,
      ),
    };
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(api.answerReads, greaterThan(reads));
    expect(api.submissions, 0);
    expect(live.answers['q']!.answer, ['B']);
    expect(live.draftAnswers, isEmpty);
  });

  testWidgets(
    'edits replace the queued automatic answer with the latest draft',
    (tester) async {
      final live = await prepareDelayed(tester);
      controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
      await tester.pump(const Duration(seconds: 31));
      expect(api.submissions, 1);
      expect(live.answers['q']!.answer, ['B']);
      expect(live.autoStates['q'], '答案已提交');
      expect(api.submittedAnswers, [
        ['B'],
      ]);
    },
  );

  testWidgets('manual submission immediately cancels the timer', (
    tester,
  ) async {
    final live = await prepareDelayed(tester);
    await controller.submitAnswer(live, live.questions['q']!, ['B']);
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 1);
    expect(api.submittedAnswers, [
      ['B'],
    ]);
  });

  testWidgets('a cancelled final lookup cannot replace a newer manual answer', (
    tester,
  ) async {
    final live = await prepareDelayed(tester);
    api.pendingAnswers = Completer();
    await tester.pump(const Duration(seconds: 30));
    await controller.submitAnswer(live, live.questions['q']!, ['B']);
    api.pendingAnswers!.complete({
      'q': const AnswerRecord(
        problemId: 'q',
        answer: ['A'],
        source: AnswerSource.server,
      ),
    });
    await tester.pump();
    expect(api.submissions, 1);
    expect(live.answers['q']!.answer, ['B']);
    expect(live.answers['q']!.source, AnswerSource.local);
  });

  testWidgets(
    'a cancelled final lookup failure cannot overwrite manual draft status',
    (tester) async {
      final live = await prepareDelayed(tester);
      api.pendingAnswers = Completer();
      await tester.pump(const Duration(seconds: 30));
      controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
      api.pendingAnswers!.completeError(const ApiFailure('late query failure'));
      await tester.pump();
      expect(api.submissions, 0);
      expect(live.draftAnswers['q'], ['B']);
      expect(live.autoStates['q'], contains('秒后自动提交'));
    },
  );

  testWidgets('AI fills a draft then waits the full default delay', (
    tester,
  ) async {
    resetForWidgetTest();
    disposeController();
    final ai = DeferredAi();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
            now: automationTestNow,
            connectSockets: false,
          )
          ..account = const Account(id: 'u', name: '测试')
          ..settings = AppSettings(
            autoAnswer: true,
            autoSubmit: true,
            answerMode: AnswerMode.ai,
          );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(live, unlock());
    ai.result.complete('A');
    await tester.pump();
    expect(live.draftAnswers['q'], ['A']);
    await tester.pump(const Duration(seconds: 29));
    expect(api.submissions, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(api.submissions, 1);
  });

  testWidgets('manual editing while AI generates discards the late AI result', (
    tester,
  ) async {
    resetForWidgetTest();
    disposeController();
    final ai = DeferredAi();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
            now: automationTestNow,
            connectSockets: false,
          )
          ..account = const Account(id: 'u', name: '测试')
          ..settings = AppSettings(
            autoAnswer: true,
            autoSubmit: true,
            answerMode: AnswerMode.ai,
          );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(live, unlock());
    await tester.pump();
    expect(ai.received, isNotNull);
    controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
    ai.result.complete('A');
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 1);
    expect(live.answers['q']!.answer, ['B']);
    expect(live.autoStates['q'], '答案已提交');
  });

  testWidgets(
    'a late AI failure cannot replace a manually edited draft state',
    (tester) async {
      resetForWidgetTest();
      disposeController();
      final ai = DeferredAi();
      controller =
          AppController(
              api: api,
              ai: ai,
              store: MemoryStore(),
              background: NoBackground(),
              autostart: const NoAutostart(),
              startTimers: false,
              now: automationTestNow,
              connectSockets: false,
            )
            ..account = const Account(id: 'u', name: '测试')
            ..settings = AppSettings(
              autoAnswer: true,
              autoSubmit: true,
              answerMode: AnswerMode.ai,
            );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      await controller.syncAnswers(live);
      await controller.processEvent(live, unlock());
      await tester.pump();
      expect(ai.received, isNotNull);
      controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
      ai.result.completeError(const ApiFailure('late AI failure'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(api.submissions, 1);
      expect(live.answers['q']!.answer, ['B']);
      expect(live.autoStates['q'], '答案已提交');
    },
  );

  testWidgets(
    'closing or editing while final answer check waits prevents POST',
    (tester) async {
      final live = await prepareDelayed(tester);
      api.pendingAnswers = Completer();
      await tester.pump(const Duration(seconds: 30));
      controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
      await controller.processEvent(live, {
        'op': 'problemfinished',
        'prob': 'q',
      });
      api.pendingAnswers!.complete({});
      await tester.pump();
      expect(api.submissions, 0);
      expect(live.draftAnswers['q'], ['B']);
    },
  );

  testWidgets('insufficient answer time never shortens the configured delay', (
    tester,
  ) async {
    resetForWidgetTest();
    controller.settings = AppSettings(
      autoAnswer: true,
      autoSubmit: true,
      fixedAnswer: 'A',
    );
    final live = await controller.enter(lesson);
    await controller.processEvent(live, hello());
    await controller.syncAnswers(live);
    await controller.processEvent(live, {
      'op': 'unlockproblem',
      'problem': {
        'prob': 'q',
        'dt': controller.now().millisecondsSinceEpoch,
        'limit': 10,
      },
    });
    await tester.pump();
    expect(live.draftAnswers['q'], ['A']);
    expect(live.autoStates['q'], '答题剩余时间不足，已取消自动提交');
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 0);
  });
  test(
    'old timeline questions do not change the teacher current presentation',
    () async {
      api.decks['old'] = const Presentation(
        id: 'old',
        title: '旧课件',
        slides: [
          Slide(
            id: 'os',
            index: 0,
            imageUrl: '',
            question: Question(id: 'oldq', body: '旧题', type: 1),
          ),
        ],
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(
        live,
        hello([
          {
            'type': 'problem',
            'pres': 'old',
            'prob': 'oldq',
            'limit': 60,
            'dt': 1,
          },
        ]),
      );
      expect(live.presentationId, 'p');
      expect(live.questions.containsKey('oldq'), true);
    },
  );
  test('logout invalidates a checkin response that arrives later', () async {
    api.pendingCheckin = Completer();
    final future = controller.enter(lesson);
    await controller.logout();
    api.pendingCheckin!.complete(
      const ClassroomSession(
        userId: 'u',
        lessonId: 'l',
        bearer: 'b',
        lessonToken: 't',
      ),
    );
    await expectLater(future, throwsA(isA<ApiFailure>()));
    expect(controller.classrooms, isEmpty);
  });
  test(
    'AI uses question page even after browsing away; disabling cancels submit',
    () async {
      disposeController();
      final ai = DeferredAi();
      controller = AppController(
        api: api,
        store: MemoryStore(),
        background: NoBackground(),
        autostart: const NoAutostart(),
        ai: ai,
        startTimers: false,
        now: automationTestNow,
        connectSockets: false,
      )..account = const Account(id: 'u', name: '测试');
      controller.settings = AppSettings(
        autoAnswer: true,
        autoSubmit: true,
        answerMode: AnswerMode.ai,
        baseUrl: 'https://example.com/v1',
        slideScope: SlideScope.currentAndNext,
      );
      final live = await controller.enter(lesson);
      await controller.processEvent(live, hello());
      controller.selectSlide(live, 1);
      final answering = controller.processEvent(live, unlock());
      for (var i = 0; i < 15 && ai.received == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(ai.received!.map((slide) => slide.id), ['s1', 's2']);
      controller.settings.autoAnswer = false;
      ai.result.complete('A');
      await answering;
      expect(api.submissions, 0);
    },
  );
}
