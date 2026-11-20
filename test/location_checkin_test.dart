import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/app_autostart.dart';
import 'package:ykt_helper/services/background_runtime.dart';

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Background extends BackgroundRuntime {
  @override
  bool get supported => false;
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
  @override
  Future<void> configure({
    required bool enabled,
    required bool eligible,
  }) async {}
}

const _lesson = Lesson(
  id: 'lesson',
  courseId: 'course',
  classroomId: 'classroom',
  title: '课堂',
  live: true,
);
const _session = ClassroomSession(
  userId: 'user',
  lessonId: 'lesson',
  bearer: 'http',
  lessonToken: 'ws',
);

class _Api extends RainApi {
  AttendanceStatus attendanceValue = AttendanceStatus.unknown;
  bool attendanceFails = false, signed = false, available = true;
  int round = 0, posts = 0, statusQueries = 0;
  Completer<void>? beforeSubmit;
  Completer<LocationCheckin>? pendingStatus;
  LocationCheckin get current => LocationCheckin(
    signed: signed,
    available: available,
    latitude: 30,
    longitude: 120,
    address: '教学楼',
    roundId: '$round',
  );
  @override
  Future<ClassroomSession> checkin(String lessonId) async => _session;
  @override
  Future<AttendanceStatus> attendance(Lesson lesson) async {
    if (attendanceFails) throw const ApiFailure('报告延迟');
    return attendanceValue;
  }

  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<List<Lesson>> liveLessons() async => [];
  @override
  Future<void> logout() async {}
  @override
  void locationRoundChanged(String lessonId) {
    round++;
    signed = false;
  }

  @override
  Future<LocationCheckin> locationStatus(ClassroomSession session) async {
    statusQueries++;
    return await pendingStatus?.future ?? current;
  }

  @override
  Future<bool> locationSubmit(
    ClassroomSession session,
    LocationCheckin confirmed, {
    bool Function()? shouldSubmit,
  }) async {
    await beforeSubmit?.future;
    if (shouldSubmit != null && !shouldSubmit()) return false;
    if (confirmed.fingerprint != current.fingerprint) {
      throw const ApiFailure('轮次变化');
    }
    posts++;
    signed = true;
    return true;
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late AppController controller;
  setUp(() {
    api = _Api();
    controller = AppController(
      api: api,
      store: _Store(),
      background: _Background(),
      autostart: _Autostart(),
      startTimers: false,
      connectSockets: false,
    )..account = const Account(id: 'user', name: '学生');
  });
  tearDown(() => controller.dispose());

  test(
    'position automation is separate and defaults off for previous installations',
    () {
      expect(AppSettings(autoEnter: true).autoLocationCheckin, false);
      expect(
        AppSettings.fromJson({'autoEnter': true}).autoLocationCheckin,
        false,
      );
      expect(
        AppSettings.fromJson(
          AppSettings(autoEnter: true, autoLocationCheckin: true).toJson(),
        ).autoLocationCheckin,
        true,
      );
    },
  );

  test('automatic entry alone never submits a position check-in', () async {
    controller.settings = AppSettings(autoEnter: true);
    final live = await controller.enter(_lesson);
    await _flush();
    await controller.syncAttendance(live);
    expect(api.posts, 0);
    expect(api.statusQueries, greaterThan(0));
  });

  test(
    'read-only position sync recognizes a previous check-in with automation off',
    () async {
      api.signed = true;
      final live = await controller.enter(_lesson);
      await _flush();
      expect(live.attendance, AttendanceStatus.signed);
      expect(live.location?.signed, true);
      expect(api.posts, 0);
    },
  );

  test(
    'accepted automatic position preference signs once per round and updates main attendance',
    () async {
      controller.settings = AppSettings(
        autoEnter: true,
        autoLocationCheckin: true,
      );
      final live = await controller.enter(_lesson);
      await _flush();
      expect(api.posts, 1);
      expect(live.location?.signed, true);
      expect(live.attendance, AttendanceStatus.signed);
      expect(live.attendanceError, isNull);
      await controller.syncAttendance(live);
      expect(api.posts, 1);
      await controller.processEvent(live, {'op': 'locationcheckinext'});
      await _flush();
      expect(api.posts, 2);
      expect(live.location?.roundId, '1');
      expect(live.attendance, AttendanceStatus.signed);
    },
  );

  test(
    'enabling position automation checks existing classrooms immediately',
    () async {
      final live = await controller.enter(_lesson);
      await _flush();
      expect(api.posts, 0);
      await controller.saveSettings(
        AppSettings(autoEnter: true, autoLocationCheckin: true),
      );
      await _flush();
      expect(api.posts, 1);
      expect(live.location?.signed, true);
    },
  );

  test(
    'manual confirmed position is attendance evidence despite delayed report',
    () async {
      final live = await controller.enter(_lesson);
      await _flush();
      final target = await controller.locationStatus(live);
      expect(await controller.confirmLocation(live, target), true);
      api.attendanceFails = true;
      await controller.syncAttendance(live);
      expect(live.checkinText, '已签到');
      expect(live.attendanceError, isNull);
      expect(await controller.loadAttendance(_lesson), AttendanceStatus.signed);
      await expectLater(
        controller.loadAttendance(
          const Lesson(
            id: 'lesson',
            courseId: 'other',
            classroomId: 'classroom',
            title: '其他课程',
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  test(
    'location evidence is invalidated on a new round instead of retained forever',
    () async {
      final live = await controller.enter(_lesson);
      await _flush();
      final target = await controller.locationStatus(live);
      await controller.confirmLocation(live, target);
      expect(live.attendance, AttendanceStatus.signed);
      await controller.processEvent(live, {'op': 'locationcheckinext'});
      await _flush();
      expect(live.location?.signed, false);
      expect(live.attendance, AttendanceStatus.unknown);
      expect(api.posts, 1);
    },
  );

  for (final event in ['locationcheckinend', 'lessonfinished']) {
    test(
      'confirmed position remains signed when the round ends via $event',
      () async {
        final live = await controller.enter(_lesson);
        await _flush();
        final target = await controller.locationStatus(live);
        await controller.confirmLocation(live, target);
        await controller.processEvent(live, {'op': event});
        await _flush();
        expect(live.location?.signed, true);
        expect(live.location?.available, false);
        expect(live.attendance, AttendanceStatus.signed);
      },
    );
  }

  for (final action in ['disabled', 'lesson-ended', 'background', 'logout']) {
    test('late automatic eligibility cannot submit after $action', () async {
      api.beforeSubmit = Completer<void>();
      controller.settings = AppSettings(
        autoEnter: true,
        autoLocationCheckin: true,
      );
      final live = await controller.enter(_lesson);
      await _flush();
      if (action == 'disabled') {
        await controller.saveSettings(AppSettings(autoEnter: true));
      } else if (action == 'lesson-ended') {
        await controller.processEvent(live, {'op': 'lessonfinished'});
      } else if (action == 'background') {
        controller.setForeground(false);
      } else {
        await controller.logout();
      }
      api.beforeSubmit!.complete();
      await _flush();
      expect(api.posts, 0);
      expect(live.location?.signed, isNot(true));
    });
  }

  test(
    'ordinary automation disable also clears position automation preference',
    () async {
      await controller.saveSettings(AppSettings(autoLocationCheckin: true));
      expect(controller.settings.autoLocationCheckin, false);
    },
  );
}
