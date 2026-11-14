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
  bool failSubmit = false, failSync = false;
  final decks = <String, Presentation>{};
  Map<String, AnswerRecord> remote = {};
  Completer<Map<String, AnswerRecord>>? pendingAnswers;
  Completer<ClassroomSession>? pendingCheckin;
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
  }) async => decks[presentationId]!;
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
    if (failSubmit) throw const ApiFailure('test response lost');
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
    options: {'A': '2', 'B': '3'},
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
      'dt': dt ?? DateTime.now().millisecondsSinceEpoch,
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
      connectSockets: false,
    );
    controller.account = const Account(id: 'u', name: '测试');
  });
  tearDown(() => controller.dispose());
  void resetForWidgetTest() {
    // Create Future chains inside the widget test's fake async zone.
    controller.dispose();
    controller = AppController(
      api: api,
      store: MemoryStore(),
      background: NoBackground(),
      autostart: const NoAutostart(),
      startTimers: false,
      connectSockets: false,
    )..account = const Account(id: 'u', name: '测试');
  }

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
              options: const {'A': '甲', 'B': '乙'},
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
        1 || 6 => ['B'],
        2 || 3 => ['A', 'B'],
        4 => ['第一空', '第二空'],
        _ => {'content': '第一空;第二空', 'pics': [], 'videos': []},
      };
      expect(live.draftAnswers['q'], expected);
      expect(live.autoStates['q'], '答案已填充，待确认提交');
      expect(api.submissions, 0);
    });
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

  test(
    'saving fixed automation requires every category to be filled',
    () async {
      controller.account = null;
      for (final missing in ['single', 'multiple', 'subjective']) {
        final settings = AppSettings(
          autoAnswer: true,
          fixedSingleAnswer: missing == 'single' ? ' ' : 'A',
          fixedMultipleAnswer: missing == 'multiple' ? '' : 'AB',
          fixedSubjectiveAnswer: missing == 'subjective' ? '\n' : '文字答案',
        );
        await expectLater(
          controller.saveSettings(settings),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.message,
              'message',
              '请填写三类固定答案后保存',
            ),
          ),
        );
        expect(controller.settings.autoAnswer, false);
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
    },
  );

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
    controller.dispose();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
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
    controller.dispose();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
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
      controller.dispose();
      controller = AppController(
        api: api,
        store: MemoryStore(),
        background: NoBackground(),
        autostart: const NoAutostart(),
        startTimers: false,
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
  test('missing or invalid stored delay defaults to thirty seconds', () {
    expect(AppSettings().autoSubmitDelaySeconds, 30);
    expect(AppSettings.fromJson({}).autoSubmitDelaySeconds, 30);
    expect(
      AppSettings.fromJson({
        'autoSubmitDelaySeconds': 0,
      }).autoSubmitDelaySeconds,
      30,
    );
    final restored = AppSettings.fromJson(
      AppSettings(autoSubmitDelaySeconds: 47).toJson(),
    );
    expect(restored.autoSubmitDelaySeconds, 47);
  });

  test('saving an invalid automatic submission delay is rejected', () async {
    await expectLater(
      controller.saveSettings(
        AppSettings(
          autoAnswer: true,
          autoSubmit: true,
          fixedAnswer: 'A',
          autoSubmitDelaySeconds: 0,
        ),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(controller.settings.autoSubmitDelaySeconds, 30);
  });

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

  testWidgets('edits preserve the draft and cancel the old automatic answer', (
    tester,
  ) async {
    final live = await prepareDelayed(tester);
    controller.updateAnswerDraft(live, live.questions['q']!, ['B']);
    await tester.pump(const Duration(seconds: 31));
    expect(api.submissions, 0);
    expect(live.draftAnswers['q'], ['B']);
    expect(live.autoStates['q'], '答案已修改，待确认提交');
    await controller.syncAnswers(live);
    expect(live.draftAnswers['q'], ['B']);
    await controller.submitAnswer(live, live.questions['q']!, ['B']);
    expect(api.submittedAnswers, [
      ['B'],
    ]);
  });

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
      expect(live.autoStates['q'], '答案已修改，待确认提交');
    },
  );

  testWidgets('AI fills a draft then waits the full default delay', (
    tester,
  ) async {
    resetForWidgetTest();
    controller.dispose();
    final ai = DeferredAi();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
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
    controller.dispose();
    final ai = DeferredAi();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
            autostart: const NoAutostart(),
            startTimers: false,
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
    expect(api.submissions, 0);
    expect(live.draftAnswers['q'], ['B']);
    expect(live.autoStates['q'], '答案已修改，待确认提交');
  });

  testWidgets(
    'a late AI failure cannot replace a manually edited draft state',
    (tester) async {
      resetForWidgetTest();
      controller.dispose();
      final ai = DeferredAi();
      controller =
          AppController(
              api: api,
              ai: ai,
              store: MemoryStore(),
              background: NoBackground(),
              autostart: const NoAutostart(),
              startTimers: false,
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
      expect(api.submissions, 0);
      expect(live.draftAnswers['q'], ['B']);
      expect(live.autoStates['q'], '答案已修改，待确认提交');
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
        'dt': DateTime.now().millisecondsSinceEpoch,
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
      controller.dispose();
      final ai = DeferredAi();
      controller = AppController(
        api: api,
        store: MemoryStore(),
        background: NoBackground(),
        autostart: const NoAutostart(),
        ai: ai,
        startTimers: false,
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
