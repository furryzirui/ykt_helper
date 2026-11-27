import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
  title: '同一课堂 ID',
  live: true,
);

class _Store implements KeyValueStore {
  final Map<String, String> values;
  final reads = <String>[];
  final writes = <({String key, String value})>[];
  final deletes = <String>[];
  _Store([Map<String, String> seed = const {}]) : values = Map.of(seed);

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add((key: key, value: value));
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes.add(key);
    values.remove(key);
  }
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

class _Autostart extends AppAutostart {
  @override
  bool get supported => false;
}

class _Logs extends AppLogs {
  @override
  Future<void> initialize() async {}
}

class _Api extends RainApi {
  final restoredCookies = <String>[];
  final profileStarted = Completer<void>();
  final logoutStarted = Completer<void>();
  final checkinStarted = Completer<void>();
  Completer<Account>? delayedProfile;
  Completer<void>? delayedLogout;
  Completer<ClassroomSession>? delayedCheckin;
  int exports = 0, profileCalls = 0, checkinCalls = 0;
  final own = <String, AnswerRecord>{};
  _Api(RainServer server, Future<void> Function(String) changed)
    : super(server: server, onCookiesChanged: changed);

  @override
  Future<void> restoreCookies(String serialized) async {
    restoredCookies.add(serialized);
  }

  @override
  Future<Account> profile() async {
    profileCalls++;
    if (!profileStarted.isCompleted) profileStarted.complete();
    final account = delayedProfile == null
        ? Account(id: 'same-user', name: server.label)
        : await delayedProfile!.future;
    userId = account.id;
    return account;
  }

  @override
  Future<String> exportCookies() async {
    exports++;
    return 'cookies-${server.name}';
  }

  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<List<Lesson>> liveLessons() async => [];
  @override
  Future<ClassroomSession> checkin(String lessonId) {
    checkinCalls++;
    if (!checkinStarted.isCompleted) checkinStarted.complete();
    return delayedCheckin?.future ?? Future.value(classroom(lessonId));
  }

  ClassroomSession classroom(String lessonId) => ClassroomSession(
    server: server,
    userId: 'same-user',
    lessonId: lessonId,
    bearer: 'http-${server.name}',
    lessonToken: 'ws-${server.name}',
  );
  @override
  Future<AttendanceStatus> attendance(Lesson lesson) async =>
      AttendanceStatus.unknown;
  @override
  Future<LocationCheckin> locationStatus(ClassroomSession session) async =>
      const LocationCheckin(signed: false, available: false);
  @override
  Future<Map<String, AnswerRecord>> ownAnswers(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
  }) async => Map.of(own);
  @override
  Future<void> logout() async {
    if (!logoutStarted.isCompleted) logoutStarted.complete();
    await delayedLogout?.future;
    // Exercise the real persistence callback, including writing an empty
    // cookie snapshot. A no-op logout would hide cross-deployment writes.
    await super.logout();
  }
}

class _Fixture {
  final _Store store;
  final instances = <_Api>[];
  late final AppController controller;
  _Fixture([_Store? store]) : store = store ?? _Store() {
    controller = AppController(
      apiFactory: (server) {
        final api = _Api(
          server,
          (value) => this.store.write(
            server == RainServer.standard
                ? 'cookies'
                : 'cookies:${server.name}',
            value,
          ),
        );
        instances.add(api);
        return api;
      },
      store: this.store,
      background: _Runtime(),
      autostart: _Autostart(),
      logs: _Logs(),
      startTimers: false,
      connectSockets: false,
    );
  }
  _Api get api => controller.api as _Api;
}

String _journal(String choice) => jsonEncode({
  _lesson.id: [
    {
      'problemId': 'question',
      'answer': [choice],
      'score': 0,
    },
  ],
});

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default deployment restores the pre-upgrade cookie and answer keys',
    () async {
      final store = _Store({
        'cookies': 'legacy-cookie',
        'answers:same-user': _journal('A'),
        'cookies:changjiang': 'other-cookie',
        'answers:changjiang:same-user': _journal('B'),
      });
      final fixture = _Fixture(store);
      addTearDown(fixture.controller.dispose);
      await fixture.controller.initialize();
      expect(fixture.controller.server, RainServer.standard);
      expect(fixture.api.restoredCookies, ['legacy-cookie']);
      final live = await fixture.controller.enter(_lesson);
      expect(live.answers['question']!.answer, ['A']);
      expect(store.reads, containsAll(['cookies', 'answers:same-user']));
      expect(store.reads, isNot(contains('cookies:changjiang')));
      expect(store.reads, isNot(contains('answers:changjiang:same-user')));
      expect(store.reads, isNot(contains('cookies:standard')));
    },
  );

  for (final server in RainServer.values.where(
    (value) => value != RainServer.standard,
  )) {
    test(
      '${server.name} restores only its own cookie and same-user answers',
      () async {
        final store = _Store({
          'rainServer': server.name,
          'cookies': 'legacy-cookie',
          'answers:same-user': _journal('A'),
          'cookies:${server.name}': 'selected-cookie',
          'answers:${server.name}:same-user': _journal('B'),
        });
        final fixture = _Fixture(store);
        addTearDown(fixture.controller.dispose);
        await fixture.controller.initialize();
        expect(fixture.controller.server, server);
        expect(fixture.api.restoredCookies, ['selected-cookie']);
        expect(fixture.instances.first.restoredCookies, isEmpty);
        expect(fixture.instances.first.profileCalls, 0);
        final live = await fixture.controller.enter(_lesson);
        expect(live.session.server, server);
        expect(live.answers['question']!.answer, ['B']);
        expect(store.reads, isNot(contains('cookies')));
        expect(store.reads, isNot(contains('answers:same-user')));
        expect(store.values['cookies'], 'legacy-cookie');
        expect(store.values['answers:same-user'], _journal('A'));
        expect(store.writes.where((write) => write.key == 'cookies'), isEmpty);
      },
    );
  }

  test(
    'a logged-in account must log out before changing deployments',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.controller.dispose);
      await fixture.controller.loginCompleted();
      final oldApi = fixture.api;
      await expectLater(
        fixture.controller.selectServer(RainServer.changjiang),
        throwsA(isA<ApiFailure>()),
      );
      expect(identical(fixture.api, oldApi), true);
      expect(fixture.controller.server, RainServer.standard);
      expect(fixture.controller.account?.name, RainServer.standard.label);
      expect(fixture.store.values['rainServer'], isNull);
      expect(fixture.instances, hasLength(1));
    },
  );

  test(
    'answer writes for identical user and lesson IDs stay deployment-scoped',
    () async {
      final store = _Store({
        'rainServer': RainServer.changjiang.name,
        'cookies:changjiang': 'selected-cookie',
        'answers:changjiang:same-user': _journal('B'),
        'answers:same-user': _journal('A'),
        'answers:huanghe:same-user': _journal('D'),
      });
      final fixture = _Fixture(store);
      addTearDown(fixture.controller.dispose);
      await fixture.controller.initialize();
      final live = await fixture.controller.enter(_lesson);
      fixture.api.own['new-question'] = const AnswerRecord(
        problemId: 'new-question',
        answer: ['C'],
        source: AnswerSource.server,
      );
      live.presentations['deck'] = const Presentation(
        id: 'deck',
        title: '',
        slides: [],
      );
      await fixture.controller.syncAnswers(live);
      final selected = object(
        jsonDecode(store.values['answers:changjiang:same-user']!),
      );
      expect(
        array(
          selected[_lesson.id],
        ).map(object).map((answer) => answer['problemId']),
        containsAll(['question', 'new-question']),
      );
      expect(store.values['answers:same-user'], _journal('A'));
      expect(store.values['answers:huanghe:same-user'], _journal('D'));
      expect(
        store.writes
            .where((write) => write.key.startsWith('answers:'))
            .map((write) => write.key)
            .toSet(),
        {'answers:changjiang:same-user'},
      );
    },
  );

  test(
    'a profile arriving after a deployment change cannot restore the old login',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.controller.dispose);
      final oldApi = fixture.api;
      final late = Completer<Account>();
      oldApi.delayedProfile = late;
      final login = fixture.controller.loginCompleted();
      await oldApi.profileStarted.future;
      await fixture.controller.selectServer(RainServer.huanghe);
      late.complete(const Account(id: 'same-user', name: '旧服务端账号'));
      await login;
      expect(fixture.controller.server, RainServer.huanghe);
      expect(fixture.controller.account, isNull);
      expect(oldApi.exports, 0);
      expect(
        fixture.store.writes.where((write) => write.key == 'cookies:huanghe'),
        isEmpty,
      );
      await fixture.controller.loginCompleted();
      expect(fixture.controller.account?.name, RainServer.huanghe.label);
      expect(fixture.store.values['cookies:huanghe'], 'cookies-huanghe');
      expect(fixture.controller.classrooms, isEmpty);
    },
  );

  test(
    'changing deployments waits for logout and does not delete the target data',
    () async {
      final store = _Store({
        'answers:same-user': _journal('A'),
        'cookies:changjiang': 'target-cookie',
        'answers:changjiang:same-user': _journal('B'),
      });
      final fixture = _Fixture(store);
      addTearDown(fixture.controller.dispose);
      await fixture.controller.loginCompleted();
      final oldApi = fixture.api;
      final gate = Completer<void>();
      oldApi.delayedLogout = gate;
      final logout = fixture.controller.logout();
      await oldApi.logoutStarted.future;
      var switched = false;
      final switching = fixture.controller
          .selectServer(RainServer.changjiang)
          .then((_) {
            switched = true;
          });
      try {
        await _settle();
        expect(switched, false);
        expect(fixture.controller.server, RainServer.standard);
        expect(fixture.instances, hasLength(1));
      } finally {
        gate.complete();
      }
      await logout;
      await switching;
      expect(fixture.controller.server, RainServer.changjiang);
      expect(fixture.controller.account, isNull);
      expect(store.values['cookies'], anyOf(isNull, '[]'));
      expect(store.values.containsKey('answers:same-user'), false);
      expect(store.values['cookies:changjiang'], 'target-cookie');
      expect(store.values['answers:changjiang:same-user'], _journal('B'));
      expect(store.deletes, isNot(contains('cookies:changjiang')));
      expect(store.deletes, isNot(contains('answers:changjiang:same-user')));
      expect(store.values['rainServer'], RainServer.changjiang.name);
    },
  );

  test(
    'a late old-deployment checkin cannot remove the new deployment pending entry',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.controller.dispose);
      await fixture.controller.loginCompleted();
      final oldApi = fixture.api;
      final oldResponse = Completer<ClassroomSession>();
      oldApi.delayedCheckin = oldResponse;
      final oldEntry = fixture.controller.enter(_lesson);
      final oldRejected = expectLater(oldEntry, throwsA(isA<ApiFailure>()));
      await oldApi.checkinStarted.future;
      await fixture.controller.logout();
      await fixture.controller.selectServer(RainServer.changjiang);
      await fixture.controller.loginCompleted();

      final currentApi = fixture.api;
      final currentResponse = Completer<ClassroomSession>();
      currentApi.delayedCheckin = currentResponse;
      final currentEntry = fixture.controller.enter(_lesson);
      await currentApi.checkinStarted.future;
      oldResponse.complete(oldApi.classroom(_lesson.id));
      await oldRejected;

      final repeatedEntry = fixture.controller.enter(_lesson);
      try {
        expect(identical(repeatedEntry, currentEntry), true);
        expect(currentApi.checkinCalls, 1);
        expect(fixture.controller.classrooms, isEmpty);
      } finally {
        currentResponse.complete(currentApi.classroom(_lesson.id));
      }
      final live = await currentEntry;
      expect(await repeatedEntry, same(live));
      expect(fixture.controller.classrooms[_lesson.id], same(live));
      expect(live.session.server, RainServer.changjiang);
      expect(currentApi.checkinCalls, 1);
    },
  );
}
