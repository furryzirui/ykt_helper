import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/live_connection.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';
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

class FakeRain extends RainApi {
  int checkins = 0, submissions = 0;
  bool failSubmit = false, failSync = false;
  final decks = <String, Presentation>{};
  Map<String, AnswerRecord> remote = {};
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
    if (failSync) throw const ApiFailure('test sync unavailable');
    return remote;
  }

  @override
  Future<void> submit(
    ClassroomSession session,
    Question question,
    dynamic answer,
  ) async {
    submissions++;
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
      startTimers: false,
      connectSockets: false,
    );
    controller.account = const Account(id: 'u', name: '测试');
  });
  tearDown(() => controller.dispose());
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
  test('AI answers also remain drafts when auto submit is off', () async {
    final ai = DeferredAi();
    controller.dispose();
    controller =
        AppController(
            api: api,
            ai: ai,
            store: MemoryStore(),
            background: NoBackground(),
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
  test(
    'duplicate unlock cannot submit twice and the submitted answer survives sync',
    () async {
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
  test(
    'a lost submit response is not blindly repeated on another event',
    () async {
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
      await Future<void>.delayed(Duration.zero);
      expect(api.submissions, 1);
      expect(live.answers.containsKey('q'), false);
    },
  );
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
