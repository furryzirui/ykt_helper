import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/app_logs.dart';
import 'package:ykt_helper/services/background_runtime.dart';

const _lesson = Lesson(
  id: 'lesson',
  courseId: 'course',
  classroomId: 'classroom',
  title: '课堂',
  live: true,
);
const _question = Question(
  id: 'question',
  type: 1,
  body: '题目',
  options: {'A': '一', 'B': '二', 'C': '三'},
);

class _Store implements KeyValueStore {
  final values = <String, String>{
    'cookies': '[{"fixture":"restored-session"}]',
    'settings': jsonEncode(
      AppSettings(autoEnter: true, autoLocationCheckin: true).toJson(),
    ),
  };
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Logs extends AppLogs {
  @override
  Future<void> initialize() async {}
}

class _NoDirectories extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async =>
      throw UnsupportedError('No legacy fixture files');
}

class _Startup extends AppAutostart {
  @override
  bool get supported => false;
}

class _Runtime extends BackgroundRuntime {
  @override
  bool get supported => false;
  @override
  Future<BackgroundRuntimeState?> status() async =>
      const BackgroundRuntimeState(enabled: false);
  @override
  Future<void> configure({
    required BackgroundServiceMode mode,
    DateTime? deadline,
  }) async {}
  @override
  Future<bool> setEnabled(bool enabled) async => true;
}

class _Api extends RainApi {
  int liveReads = 0,
      checkins = 0,
      presentations = 0,
      answers = 0,
      posts = 0,
      attendanceReads = 0;
  final remote = <String, AnswerRecord>{};
  @override
  Future<void> restoreCookies(String serialized) async {}
  @override
  Future<Account> profile() async => const Account(id: 'user', name: '学生');
  @override
  Future<List<Course>> courses() async => [
    const Course(courseId: 'course', classroomId: 'classroom', name: '课程'),
  ];
  @override
  Future<List<Lesson>> liveLessons() async {
    liveReads++;
    return [_lesson];
  }

  @override
  Future<ClassroomSession> checkin(String lessonId) async {
    checkins++;
    return const ClassroomSession(
      userId: 'user',
      lessonId: 'lesson',
      bearer: 'http',
      lessonToken: 'ws',
    );
  }

  @override
  Future<AttendanceStatus> attendance(Lesson lesson) async {
    attendanceReads++;
    return AttendanceStatus.unknown;
  }

  @override
  Future<LocationCheckin> locationStatus(ClassroomSession session) async =>
      const LocationCheckin(signed: false, available: false);
  @override
  Future<Presentation> presentation(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
    bool withAnswers = true,
  }) async {
    presentations++;
    return Presentation(
      id: presentationId,
      title: '课件',
      answersKnown: true,
      slides: [
        Slide(
          id: 'slide',
          index: 0,
          imageUrl: '',
          question: _question,
          ownAnswer: remote[_question.id],
        ),
      ],
    );
  }

  @override
  Future<Map<String, AnswerRecord>> ownAnswers(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
  }) async {
    answers++;
    return Map.of(remote);
  }

  @override
  Future<void> submit(
    ClassroomSession session,
    Question question,
    dynamic answer,
  ) async {
    posts++;
    remote[question.id] = AnswerRecord(
      problemId: question.id,
      answer: answer,
      source: AnswerSource.server,
    );
  }
}

void _settle(FakeAsync clock, Future<void> operation) {
  Object? failure;
  var done = false;
  operation.then(
    (_) => done = true,
    onError: (Object error) {
      failure = error;
      done = true;
    },
  );
  clock.flushMicrotasks();
  if (failure != null) throw failure!;
  expect(done, true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform previousDirectories;
  setUp(() {
    previousDirectories = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoDirectories();
  });
  tearDown(() => PathProviderPlatform.instance = previousDirectories);

  for (final automaticEntry in [false, true]) {
    test(
      'real 25 second poller does not synchronize personal answers when auto-entry=$automaticEntry',
      () {
        fakeAsync((clock) {
          final api = _Api();
          final logs = _Logs();
          final store = _Store();
          store.values['settings'] = jsonEncode(
            AppSettings(
              autoEnter: automaticEntry,
              autoLocationCheckin: automaticEntry,
            ).toJson(),
          );
          final controller = AppController(
            api: api,
            store: store,
            logs: logs,
            background: _Runtime(),
            autostart: _Startup(),
            startTimers: true,
            connectSockets: false,
            now: clock.getClock(DateTime(2026, 11, 27)).now,
          );
          _settle(clock, controller.initialize());
          final entering = controller.enter(_lesson);
          clock.flushMicrotasks();
          late LiveClass live;
          entering.then((value) => live = value);
          clock.flushMicrotasks();
          _settle(
            clock,
            controller.processEvent(live, {
              'op': 'hello',
              'presentation': 'presentation',
              'slideindex': 1,
              'timeline': [],
            }),
          );
          expect(api.presentations, 1);
          expect(api.answers, 0);
          expect(api.checkins, 1);
          expect(
            logs.entries.where(
              (entry) => entry.context['phase'] == 'syncedLiveResults',
            ),
            isEmpty,
          );
          for (var tick = 0; tick < 3; tick++) {
            clock.elapse(const Duration(seconds: 25));
            clock.flushMicrotasks();
            _settle(
              clock,
              controller.processEvent(live, {
                'op': 'hello',
                'presentation': 'presentation',
                'slideindex': 1,
                'timeline': [],
              }),
            );
            _settle(
              clock,
              controller.processEvent(live, {
                'op': 'showpresentation',
                'presentation': 'presentation',
                'slideindex': 1,
              }),
            );
            expect(api.presentations, 1);
            expect(api.answers, 0);
            expect(api.checkins, 1);
            expect(
              logs.entries.where(
                (entry) => entry.context['phase'] == 'syncedLiveResults',
              ),
              isEmpty,
            );
          }
          expect(api.liveReads, 4);
          expect(api.attendanceReads, greaterThanOrEqualTo(4));
          controller.dispose();
          clock.flushMicrotasks();
        });
      },
    );
  }
}
