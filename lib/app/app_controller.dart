import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../data/live_connection.dart';
import '../data/rain_api.dart';
import '../data/secure_store.dart';
import '../domain/models.dart';
import '../services/ai_answer.dart';
import '../services/app_logs.dart';
import '../services/app_autostart.dart';
import '../services/background_runtime.dart';
import '../services/gallery_saver.dart';
import '../services/file_export.dart';
import '../services/slide_export.dart';

class _AutomaticSubmission {
  Timer? timer;
  final int generation;
  final String settingsSnapshot;
  final Question question;
  final dynamic answer;
  _AutomaticSubmission({
    required this.generation,
    required this.settingsSnapshot,
    required this.question,
    required this.answer,
  });
}

class LiveClass {
  final Lesson lesson;
  final ClassroomSession session;
  String connectionLabel = '正在进入课堂';
  bool ended = false,
      followTeacher = true,
      syncingAnswers = false,
      answersKnown = false;
  String? error, answerSyncError, presentationId;
  int slideIndex = 0, teacherSlideIndex = 0;
  final Map<String, Presentation> presentations = {};
  final Map<String, Question> questions = {};
  final Set<String> activeProblemIds = {};
  final Map<String, AnswerRecord> answers = {};
  final Map<String, String> autoStates = {};
  final Set<String> submitting = {}, automaticAttempts = {};
  final Map<String, Json> launches = {};
  final Map<String, int> closedAtSequence = {};
  int eventSequence = 0;
  LocationCheckin? location;
  AttendanceStatus attendance = AttendanceStatus.unknown;
  String? attendanceError;
  bool syncingAttendance = false;
  String get checkinText => attendance.label;
  final Map<String, dynamic> draftAnswers = {};
  final Map<String, _AutomaticSubmission> _automaticSubmissions = {};
  final Set<String> _editedDrafts = {};
  LiveConnection? connection;
  Future<void>? answerSync;
  Future<void> eventQueue = Future.value();
  LiveClass({required this.lesson, required this.session});
  Presentation? get currentPresentation => presentations[presentationId];
  Slide? get currentSlide {
    final slides = currentPresentation?.slides;
    return slides != null && slideIndex >= 0 && slideIndex < slides.length
        ? slides[slideIndex]
        : null;
  }

  Question? get currentQuestion {
    final id = currentSlide?.question?.id;
    return questions[id] ?? currentSlide?.question;
  }
}

class AppController extends ChangeNotifier {
  late final RainApi api;
  final KeyValueStore store;
  final AiAnswerService ai;
  final BackgroundRuntime background;
  final AppAutostart autostart;
  final GallerySaver gallery;
  final AppLogs logs;
  final bool startTimers, connectSockets;
  final Dio _media = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 45),
      followRedirects: true,
    ),
  );
  AppSettings settings = AppSettings();
  Account? account;
  List<Course> courses = [];
  List<Lesson> liveLessons = [];
  final Map<String, LiveClass> classrooms = {};
  final Map<String, Future<LiveClass>> _entering = {};
  bool busy = false, initialized = false, _disposed = false;
  String? error, backgroundWarning;
  bool get backgroundEnabled => background.enabled;
  bool get backgroundSupported => background.supported;
  // Naming used by the settings pages: this is an Android system service,
  // while Windows keeps automation in its ordinary desktop process.
  bool get systemServiceSupported => backgroundSupported;
  bool get serviceSupported => backgroundSupported;
  bool get backgroundBusy => background.busy;
  // These controls are intentionally process-local. An explicit off action
  // wins over auto-start until the user explicitly turns the service on again.
  bool _serviceManuallyDisabled = false;
  bool _serviceManuallyEnabled = false;
  bool _resumeLoginPending = false;
  Future<void> _startupOperations = Future<void>.value();
  Future<void> _settingsOperations = Future<void>.value();
  int _backgroundRevision = 0;
  Timer? _poller;
  int _generation = 0;
  Future<void> _writes = Future.value();

  AppController({
    RainApi? api,
    KeyValueStore? store,
    AiAnswerService? ai,
    BackgroundRuntime? background,
    AppAutostart? autostart,
    GallerySaver? gallery,
    AppLogs? logs,
    this.startTimers = true,
    this.connectSockets = true,
  }) : store = store ?? SecureStore(),
       ai = ai ?? AiAnswerService(),
       background = background ?? BackgroundRuntime(),
       autostart = autostart ?? const AppAutostart(),
       gallery = gallery ?? const GallerySaver(),
       logs = logs ?? AppLogs() {
    this.api =
        api ??
        RainApi(
          onCookiesChanged: (cookies) => _write('cookies', cookies),
          onRequestFailure: (status) =>
              this.logs.add(AppLogEvent.api, success: false, code: status),
        );
  }
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(LiveClass live) =>
      !_disposed &&
      account?.id == live.session.userId &&
      identical(classrooms[live.lesson.id], live);
  Future<void> _write(String key, String value) {
    final operation = _writes.then((_) => store.write(key, value));
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> initialize() async {
    if (initialized || busy) return;
    final generation = _generation;
    busy = true;
    _notify();
    try {
      await logs.initialize();
      if (_disposed || generation != _generation) return;
      logs.add(AppLogEvent.startup);
      await _removeLegacyDiagnostics();
      if (_disposed || generation != _generation) return;
      final rawSettings = await store.read('settings');
      if (_disposed || generation != _generation) return;
      if (rawSettings != null) {
        settings = AppSettings.fromJson(object(jsonDecode(rawSettings)));
      }
      final cookies = await store.read('cookies');
      if (_disposed || generation != _generation) return;
      if (cookies != null && cookies != '[]') {
        await api.restoreCookies(cookies);
        if (_disposed || generation != _generation) return;
        _resumeLoginPending = true;
        final restored = await api.profile();
        if (_disposed || generation != _generation) return;
        account = restored;
        _resumeLoginPending = false;
        await _restoreAnswers();
        if (_disposed || generation != _generation) return;
      }
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      if (failure is ApiFailure && failure.code == 401) {
        _resumeLoginPending = false;
      }
      logs.add(AppLogEvent.startup, success: false);
      error = failure.toString();
    } finally {
      if (!_disposed && generation == _generation) {
        initialized = true;
        busy = false;
        _notify();
      }
    }
    if (_disposed || generation != _generation) return;
    await _updateBackground();
    if (account != null) await refresh();
    if (startTimers) {
      _poller = Timer.periodic(const Duration(seconds: 25), (_) async {
        if (busy || _disposed) return;
        if (_resumeLoginPending) {
          await retryRestoredLogin();
          return;
        }
        if (account == null) return;
        await refresh();
        for (final live in List.of(classrooms.values)) {
          if (!live.ended) {
            unawaited(syncAttendance(live));
            if (!live.syncingAnswers) await syncAnswers(live);
          }
        }
      });
    }
  }

  /// Boot can precede connectivity. Retry only the already restored session;
  /// no classroom operation runs until the server confirms the account.
  Future<void> retryRestoredLogin() async {
    if (!_resumeLoginPending || busy || _disposed) return;
    final generation = _generation;
    busy = true;
    _notify();
    try {
      final restored = await api.profile();
      if (generation != _generation || _disposed) return;
      account = restored;
      _resumeLoginPending = false;
      await _restoreAnswers();
      error = null;
    } catch (failure) {
      if (generation != _generation || _disposed) return;
      if (failure is ApiFailure && failure.code == 401) {
        _resumeLoginPending = false;
      }
      error = failure.toString();
    } finally {
      if (generation == _generation && !_disposed) {
        busy = false;
        _notify();
      }
    }
    if (generation != _generation || _disposed) return;
    await _updateBackground();
    if (account != null) await refresh();
  }

  Future<void> _removeLegacyDiagnostics() async {
    try {
      final directory = await getTemporaryDirectory();
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File &&
            RegExp(
              r'^rain-diagnostics-\d+\.json$',
            ).hasMatch(entry.uri.pathSegments.last)) {
          await entry.delete();
        }
      }
    } catch (_) {
      // An older export may already have been removed by the operating system.
    }
  }

  Future<void> loginCompleted() async {
    final generation = ++_generation;
    _resumeLoginPending = false;
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live);
    }
    final profile = await api.profile();
    if (generation != _generation || _disposed) return;
    account = profile;
    logs.add(AppLogEvent.login, success: true);
    await _restoreAnswers();
    if (generation != _generation || account?.id != profile.id || _disposed) {
      return;
    }
    await _write('cookies', await api.exportCookies());
    if (generation != _generation || account?.id != profile.id || _disposed) {
      return;
    }
    error = null;
    await refresh();
    await _updateBackground();
    _notify();
  }

  Future<void> logout() async {
    logs.add(AppLogEvent.logout);
    _generation++;
    _backgroundRevision++;
    busy = false;
    final previous = account;
    account = null;
    _resumeLoginPending = false;
    await background.setEnabled(false);
    try {
      await _configureAppAutostart(settings);
    } catch (_) {
      // Never let OS registration failure leave a logged-out account active.
      logs.add(AppLogEvent.background, success: false);
    }
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live);
      await live.connection?.close();
    }
    classrooms.clear();
    _entering.clear();
    _persistedAnswers.clear();
    courses = [];
    liveLessons = [];
    error = null;
    await api.logout();
    await _writes;
    await store.delete('cookies');
    if (previous != null) await store.delete('answers:${previous.id}');
    _serviceManuallyEnabled = false;
    backgroundWarning = null;
    _notify();
  }

  Future<void> refresh() async {
    if (account == null || busy || _disposed) return;
    final generation = _generation;
    busy = true;
    error = null;
    _notify();
    final failures = <String>[];
    await Future.wait([
      (() async {
        try {
          final result = await api.courses();
          if (generation == _generation) courses = result;
        } catch (failure) {
          failures.add('课程：$failure');
        }
      })(),
      (() async {
        try {
          final result = await api.liveLessons();
          if (generation == _generation) liveLessons = result;
        } catch (failure) {
          failures.add('动态：$failure');
        }
      })(),
    ]);
    if (generation != _generation || _disposed) {
      busy = false;
      return;
    }
    courses = courses
        .map(
          (course) => course.withLive(
            liveLessons
                .where(
                  (lesson) =>
                      lesson.classroomId == course.classroomId &&
                      lesson.courseId == course.courseId,
                )
                .map((lesson) => lesson.id)
                .toList(),
          ),
        )
        .toList();
    error = failures.isEmpty ? null : failures.join('\n');
    if (failures.isNotEmpty) {
      logs.add(AppLogEvent.refresh, success: false, count: failures.length);
    }
    busy = false;
    _notify();
    if (settings.autoEnter) {
      for (final lesson in List.of(liveLessons)) {
        if (classrooms[lesson.id]?.ended == true ||
            classrooms.containsKey(lesson.id)) {
          continue;
        }
        try {
          await enter(lesson);
        } catch (failure) {
          if (generation != _generation) return;
          error = '自动进入 ${lesson.title} 失败：$failure';
          _notify();
        }
      }
    }
  }

  Future<void> saveSettings([AppSettings? next]) {
    final input = next ?? settings;
    final snapshot = AppSettings.fromJson(input.toJson())
      ..autoSubmitDelaySeconds = input.autoSubmitDelaySeconds;
    final operation = _settingsOperations
        .catchError((Object _) {})
        .then((_) => _saveSettings(snapshot));
    _settingsOperations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _saveSettings(AppSettings input) async {
    if (_disposed) return;
    if (input.autoAnswer &&
        input.autoSubmit &&
        (input.autoSubmitDelaySeconds < 1 ||
            input.autoSubmitDelaySeconds > 3600)) {
      throw const ApiFailure('提交延迟请输入 1–3600 秒');
    }
    final candidate = AppSettings.fromJson(input.toJson());
    // Auto-start has no useful meaning without an automation trigger. This
    // normalization also lets users turn the last automation off cleanly.
    if (!candidate.autoEnter && !candidate.autoAnswer) {
      candidate.autoStartService = false;
      candidate.appAutoStart = false;
    }
    if (!autostart.supported ||
        backgroundSupported && !candidate.autoStartService) {
      candidate.appAutoStart = false;
    }
    if (candidate.autoAnswer) {
      if (candidate.answerMode == AnswerMode.fixed &&
          !candidate.hasCompleteFixedAnswers) {
        throw const ApiFailure('请填写三类固定答案后保存');
      }
      if (candidate.answerMode == AnswerMode.ai) {
        AiAnswerService.endpoint(candidate.baseUrl, 'chat/completions');
        if (candidate.model.trim().isEmpty) {
          throw const ApiFailure('请先获取并选择 AI 模型');
        }
        if (candidate.customPrompt.trim().isEmpty) {
          throw const ApiFailure('请填写 AI 提示词');
        }
      }
    }
    final previous = settings;
    await _write('settings', jsonEncode(candidate.toJson()));
    try {
      await _configureAppAutostart(candidate);
    } catch (_) {
      // A failed OS registration must not leave the UI claiming it is saved.
      await _write('settings', jsonEncode(previous.toJson()));
      try {
        await _configureAppAutostart(previous);
      } catch (_) {
        logs.add(AppLogEvent.background, success: false);
      }
      rethrow;
    }
    if (_disposed) return;
    settings = candidate;
    logs.add(AppLogEvent.settings, success: true);
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live, message: '设置已变化，已取消自动提交');
      live.automaticAttempts.clear();
    }
    await _updateBackground();
    _notify();
    if (account != null) unawaited(refresh());
    for (final live in List.of(classrooms.values)) {
      unawaited(_runAutomatic(live));
    }
  }

  Future<void> retryBackground() => _updateBackground();

  /// Explicitly enables or disables the classroom service from Settings.
  /// Disabling it suppresses auto-start until an explicit re-enable, so
  /// refreshes and classroom events cannot surprise the user by restarting it.
  Future<void> setSystemService(bool enabled) async {
    if (!backgroundSupported) return;
    if (enabled && !(settings.autoEnter || settings.autoAnswer)) {
      throw const ApiFailure('请先开启至少一项自动化');
    }
    await autostart.setSuspended(!enabled);
    _serviceManuallyDisabled = !enabled;
    _serviceManuallyEnabled = enabled;
    _notify();
    await _updateBackground();
  }

  Future<void> _configureAppAutostart(AppSettings value) {
    final enabled = value.appAutoStart;
    final eligible =
        (account != null || _resumeLoginPending) &&
        (value.autoEnter || value.autoAnswer) &&
        (!backgroundSupported || value.autoStartService) &&
        !_serviceManuallyDisabled;
    final operation = _startupOperations
        .catchError((Object _) {})
        .then((_) => autostart.configure(enabled: enabled, eligible: eligible));
    _startupOperations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _updateBackground() async {
    if (_disposed) return;
    final revision = ++_backgroundRevision;
    String? startupWarning;
    try {
      await _configureAppAutostart(settings);
    } catch (_) {
      startupWarning = '应用自启动设置失败，请重新保存自动化设置';
      logs.add(AppLogEvent.background, success: false);
    }
    if (_disposed || revision != _backgroundRevision) return;
    final hasAutomation = settings.autoEnter || settings.autoAnswer;
    if (!hasAutomation) _serviceManuallyEnabled = false;
    final autoRequested = settings.autoStartService && hasAutomation;
    final needed =
        (account != null || _resumeLoginPending) &&
        backgroundSupported &&
        hasAutomation &&
        !_serviceManuallyDisabled &&
        (_serviceManuallyEnabled || autoRequested);
    final okay = await background.setEnabled(needed);
    if (_disposed || revision != _backgroundRevision) return;
    final previousWarning = backgroundWarning;
    backgroundWarning =
        startupWarning ??
        (needed && !okay
            ? defaultTargetPlatform == TargetPlatform.iOS
                  ? 'iOS 切换后台可能暂停课堂，请保持应用前台。'
                  : '后台运行未开启，请在应用权限中允许通知和后台运行；当前仅能保证前台处理课堂。'
            : null);
    if (previousWarning != backgroundWarning || needed && okay) {
      logs.add(AppLogEvent.background, success: okay);
    }
    _notify();
  }

  Future<LessonPage> loadLessons(Course course, int page) async {
    final result = await _logged(
      AppLogEvent.lessons,
      () => api.lessons(course, page),
    );
    final current = liveLessons
        .where(
          (lesson) =>
              lesson.classroomId == course.classroomId &&
              lesson.courseId == course.courseId,
        )
        .toList();
    final byId = {for (final item in current) item.id: item};
    return LessonPage([
      if (page == 0) ...current,
      ...result.lessons
          .where((item) => page != 0 || !byId.containsKey(item.id))
          .map((item) => byId[item.id] ?? item),
    ], result.hasMore);
  }

  Future<T> _logged<T>(AppLogEvent event, Future<T> Function() action) async {
    try {
      final result = await action();
      logs.add(event, success: true);
      return result;
    } catch (error) {
      logs.add(
        event,
        success: false,
        code: error is ApiFailure && error.code != 0
            ? error.code
            : error is DioException
            ? error.response?.statusCode
            : null,
      );
      rethrow;
    }
  }

  Future<LessonDetail> loadDetail(Lesson lesson) =>
      _logged(AppLogEvent.detail, () => api.detail(lesson));

  Future<AttendanceStatus> loadAttendance(Lesson lesson) =>
      _logged(AppLogEvent.attendance, () => api.attendance(lesson));
  Future<Presentation> loadPresentation(
    Lesson lesson,
    String presentationId, {
    bool live = false,
  }) => api.presentation(
    lesson.id,
    presentationId,
    session: live ? classrooms[lesson.id]?.session : null,
  );

  Future<LiveClass> enter(Lesson lesson) {
    final existing = classrooms[lesson.id];
    if (existing != null &&
        account?.id == existing.session.userId &&
        !existing.ended) {
      return Future.value(existing);
    }
    return _entering.putIfAbsent(
      lesson.id,
      () => _logged(AppLogEvent.enter, () => _enter(lesson)).whenComplete(() {
        _entering.remove(lesson.id);
      }),
    );
  }

  Future<LiveClass> _enter(Lesson lesson) async {
    if (account == null) throw const ApiFailure('请先登录');
    if (!lesson.live) throw const ApiFailure('历史课堂请查看详情');
    final generation = _generation;
    final session = await api.checkin(lesson.id);
    if (generation != _generation || account?.id != session.userId) {
      throw const ApiFailure('账号已切换，已取消进入');
    }
    if (session.lessonId != lesson.id) throw const ApiFailure('课堂凭证与目标课堂不一致');
    final live = LiveClass(lesson: lesson, session: session);
    live.answers.addAll(_persistedAnswers[lesson.id] ?? {});
    classrooms[lesson.id] = live;
    if (connectSockets) {
      live.connection = LiveConnection(
        session,
        onStatus: (status) {
          if (_valid(live)) {
            live.connectionLabel = status;
            logs.add(AppLogEvent.connection);
            _notify();
          }
        },
        onEvent: (event) {
          if (!_valid(live)) return;
          event['_sequence'] = ++live.eventSequence;
          if (event['op'] == 'problemfinished') {
            _closeProblem(
              live,
              str(event['prob']),
              integer(event['_sequence']),
            );
          }
          // Invalidate terminal state immediately, even while an earlier event
          // is waiting for an HTTP response. AI must never outrun a finish event.
          if (event['op'] == 'lessonfinished' ||
              event['op'] == 'hello' && event['message'] == 'lesson finished') {
            live.ended = true;
            _cancelAutomaticSubmissions(live);
            live.activeProblemIds.clear();
            live.connectionLabel = '课堂已结束';
            api.locationRoundChanged(live.lesson.id);
            unawaited(live.connection?.close() ?? Future.value());
            unawaited(syncAnswers(live));
            unawaited(_updateBackground());
            _notify();
          }
          if (event['op'] == 'locationcheckinext' ||
              event['op'] == 'locationcheckinend') {
            api.locationRoundChanged(live.lesson.id);
            live.location = null;
            event['_roundInvalidated'] = true;
          }
          live.eventQueue = live.eventQueue
              .then((_) => processEvent(live, event))
              .catchError((Object failure) {
                logs.add(AppLogEvent.classroomEvent, success: false);
                if (_valid(live)) {
                  live.error = failure.toString();
                  _notify();
                }
              });
        },
      );
      unawaited(live.connection!.connect());
    }
    unawaited(syncAttendance(live));
    await _updateBackground();
    _notify();
    return live;
  }

  Future<LiveClass> scanAndEnter(String url) async {
    final generation = _generation;
    final id = await _logged(AppLogEvent.scan, () => api.scanClassroom(url));
    if (generation != _generation || account == null) {
      throw const ApiFailure('账号已退出');
    }
    final matching = liveLessons.where((lesson) => lesson.id == id).firstOrNull;
    // The scanner response identifies the lesson; obtain official metadata
    // before attaching it to a course rather than inferring the course ID.
    final detail = matching == null
        ? await api.detail(
            Lesson(
              id: id,
              courseId: '',
              classroomId: '',
              title: '课堂',
              live: true,
            ),
          )
        : null;
    final item =
        matching ??
        Lesson(
          id: id,
          courseId: detail!.lesson.courseId,
          classroomId: detail.lesson.classroomId,
          title: detail.lesson.title,
          startedAt: detail.lesson.startedAt,
          live: true,
        );
    return enter(item);
  }

  @visibleForTesting
  Future<void> processEvent(LiveClass live, Json event) async {
    if (!_valid(live) || live.ended) return;
    event['_sequence'] ??= ++live.eventSequence;
    final sequence = integer(event['_sequence']);
    final op = str(event['op']);
    if (event['lessonid'] != null && str(event['lessonid']) != live.lesson.id) {
      throw const ApiFailure('实时消息与当前课堂不一致');
    }
    if (op == 'lessonfinished' ||
        (op == 'hello' && event['message'] == 'lesson finished')) {
      live.ended = true;
      _cancelAutomaticSubmissions(live);
      live.activeProblemIds.clear();
      live.connectionLabel = '课堂已结束';
      api.locationRoundChanged(live.lesson.id);
      await live.connection?.close();
      unawaited(syncAnswers(live));
      await _updateBackground();
      _notify();
      return;
    }
    if (op == 'hello' || op == 'showpresentation') {
      if (op == 'hello') live.connectionLabel = '实时连接正常';
      final timeline = array(event['timeline']).map(object).toList();
      String id = str(event['presentation']);
      var teacherIndex = integer(event['slideindex'], 1) - 1;
      for (final entry in timeline.reversed) {
        if (entry['type'] == 'slide' && str(entry['pres']).isNotEmpty) {
          id = str(entry['pres']);
          teacherIndex = integer(entry['si'], 1) - 1;
          break;
        }
      }
      if (id.isNotEmpty) {
        await _showPresentation(live, id);
        live.teacherSlideIndex = teacherIndex;
        if (live.followTeacher) {
          selectSlide(live, teacherIndex, fromTeacher: true);
        }
      }
      for (final entry in timeline) {
        if (entry['type'] == 'problem') {
          await _unlock(live, entry, sequence: sequence, fromTimeline: true);
        }
      }
      unawaited(syncAnswers(live));
    } else if (op == 'slide' || op == 'slidenav') {
      final index =
          integer(
            op == 'slide' ? event['slideindex'] : object(event['slide'])['si'],
            1,
          ) -
          1;
      live.teacherSlideIndex = index;
      if (live.followTeacher) selectSlide(live, index, fromTeacher: true);
    } else if (op == 'unlockproblem') {
      await _unlock(live, object(event['problem']), sequence: sequence);
      unawaited(syncAnswers(live));
    } else if (op == 'problemfinished') {
      _closeProblem(live, str(event['prob']), sequence);
    } else if (op == 'probleminfo') {
      final id = str(event['problemid']);
      final question = live.questions[id];
      if (question != null && !live.closedAtSequence.containsKey(id)) {
        _applyTiming(live, question, event);
      }
    } else if (op == 'fetchtimeline') {
      for (final raw in array(event['timeline'])) {
        final entry = object(raw);
        if (entry['type'] == 'problem') {
          await _unlock(live, entry, sequence: sequence, fromTimeline: true);
        }
      }
      unawaited(syncAnswers(live));
    } else if (op == 'presentationupdated' || op == 'presentationcreated') {
      final id = str(event['presentation']);
      if (id.isNotEmpty) {
        final current = live.presentationId == id;
        final page = live.slideIndex;
        final old = live.presentations.remove(id);
        for (final slide in old?.slides ?? <Slide>[]) {
          final questionId = slide.question?.id;
          if (questionId != null) {
            _cancelAutomaticSubmission(
              live,
              questionId,
              message: '题目已变化，已取消自动提交',
            );
            live.activeProblemIds.remove(questionId);
            live.questions.remove(questionId);
          }
        }
        await _showPresentation(live, id, activate: current);
        if (current) selectSlide(live, page, fromTeacher: live.followTeacher);
        live.connection?.requestTimeline();
        unawaited(syncAnswers(live));
      }
    } else if (op == 'extendtime') {
      final data = object(event['problem']);
      final id = str(data['prob']);
      final question = live.questions[id];
      if (question == null) {
        live.error = '答题延时消息未能关联题目，请刷新课堂';
      }
      if (question != null) {
        if (!live.closedAtSequence.containsKey(question.id)) {
          _applyTiming(live, question, data);
        }
      }
    } else if (op == 'locationcheckinext' || op == 'locationcheckinend') {
      if (event['_roundInvalidated'] != true) {
        api.locationRoundChanged(live.lesson.id);
      }
      live.location = null;
      if (op == 'locationcheckinext') {
        try {
          live.location = await api.locationStatus(live.session);
        } catch (_) {
          live.error = '位置签到状态获取失败，请手动刷新';
        }
      }
    }
    _notify();
    unawaited(_runAutomatic(live));
  }

  Future<void> _showPresentation(
    LiveClass live,
    String id, {
    bool activate = true,
  }) async {
    if (!_valid(live)) return;
    if (!live.presentations.containsKey(id)) {
      final presentation = await api.presentation(
        live.lesson.id,
        id,
        session: live.session,
        withAnswers: false,
      );
      if (!_valid(live)) return;
      live.presentations[id] = presentation;
      for (final slide in presentation.slides) {
        if (slide.question != null) {
          final question = slide.question!;
          live.questions[question.id] = question;
          final launch = live.launches[question.id];
          if (launch != null) {
            live.questions[question.id] = question.launched(
              integer(launch['dt']),
              integer(launch['limit']),
            );
          }
        }
      }
    }
    if (activate && live.presentationId != id) {
      live.presentationId = id;
      live.slideIndex = 0;
      live.answersKnown = false;
    }
  }

  Future<void> _unlock(
    LiveClass live,
    Json data, {
    required int sequence,
    bool fromTimeline = false,
  }) async {
    final id = str(data['prob']);
    if (id.isEmpty) return;
    final closed = live.closedAtSequence[id];
    if (closed != null && (fromTimeline || sequence <= closed)) return;
    final previous = live.launches[id];
    if (previous != null && integer(previous['dt']) > integer(data['dt'])) {
      return;
    }
    live.launches[id] = data;
    var question = live.questions[id];
    final presentationId = str(data['pres']);
    if (question == null && presentationId.isNotEmpty) {
      await _showPresentation(live, presentationId, activate: false);
      question = live.questions[id];
    }
    if (question == null) {
      live.error = '收到题目通知，但题干尚未加载，请刷新课堂';
      return;
    }
    if (live.closedAtSequence[id] != null &&
        sequence <= live.closedAtSequence[id]!) {
      return;
    }
    if (!fromTimeline) live.closedAtSequence.remove(id);
    if (question.dt != integer(data['dt'])) {
      _cancelAutomaticSubmission(live, id);
      live._editedDrafts.remove(id);
      live.draftAnswers.remove(id);
    }
    question = question.launched(
      integer(data['dt']),
      integer(data['limit']),
      serverOffsetMillis: data['now'] == null
          ? null
          : integer(data['now']) - DateTime.now().millisecondsSinceEpoch,
    );
    live.questions[id] = question;
    if (fromTimeline && connectSockets) {
      live.activeProblemIds.remove(id);
      live.autoStates[id] = '正在确认答题时间';
      if (live.connection?.requestProblemInfo(id) != true) {
        live.error = '答题时间尚未确认，请刷新课堂连接';
      }
    } else if (_inWindow(question)) {
      live.activeProblemIds.add(id);
    } else {
      live.activeProblemIds.remove(id);
    }
  }

  void _closeProblem(LiveClass live, String id, int sequence) {
    if (id.isEmpty) return;
    _cancelAutomaticSubmission(live, id);
    live.closedAtSequence[id] = sequence;
    live.activeProblemIds.remove(id);
    live.autoStates[id] = '教师已收题';
    _notify();
  }

  void _applyTiming(LiveClass live, Question question, Json timing) {
    if (timing['limit'] is! num || (timing['dt'] == null && question.dt <= 0)) {
      _cancelAutomaticSubmission(live, question.id, message: '答题时间未确认，已取消自动提交');
      live.activeProblemIds.remove(question.id);
      live.error = '题目时限未能确认，请刷新课堂';
      return;
    }
    final updated = question.launched(
      integer(timing['dt'], question.dt),
      integer(timing['limit']),
      serverOffsetMillis: timing['now'] == null
          ? null
          : integer(timing['now']) - DateTime.now().millisecondsSinceEpoch,
    );
    if (updated.dt != question.dt) {
      _cancelAutomaticSubmission(live, question.id, message: '题目已变化，已取消自动提交');
      live._editedDrafts.remove(question.id);
      live.draftAnswers.remove(question.id);
    }
    live.questions[question.id] = updated;
    if (_inWindow(updated)) {
      live.activeProblemIds.add(question.id);
    } else {
      live.activeProblemIds.remove(question.id);
      _cancelAutomaticSubmission(live, question.id, message: '答题时间已结束，已取消自动提交');
    }
  }

  bool _inWindow(Question question) =>
      question.dt > 0 &&
      (question.limit == -1 ||
          question.limit > 0 &&
              DateTime.now().millisecondsSinceEpoch +
                      question.serverOffsetMillis <
                  question.dt + question.limit * 1000);
  void selectSlide(LiveClass live, int index, {bool fromTeacher = false}) {
    final slides = live.currentPresentation?.slides ?? [];
    if (slides.isEmpty) return;
    live.slideIndex = index.clamp(0, slides.length - 1);
    if (!fromTeacher) live.followTeacher = false;
    _notify();
  }

  void followTeacher(LiveClass live, bool enabled) {
    live.followTeacher = enabled;
    if (enabled) selectSlide(live, live.teacherSlideIndex, fromTeacher: true);
    _notify();
  }

  Future<void> syncAnswers(LiveClass live) {
    return live.answerSync ??= _syncAnswers(live).whenComplete(() {
      live.answerSync = null;
    });
  }

  Future<void> _syncAnswers(LiveClass live) async {
    if (!_valid(live) || live.syncingAnswers || live.presentations.isEmpty) {
      return;
    }
    live.syncingAnswers = true;
    live.answerSyncError = null;
    _notify();
    var known = true;
    final failures = <String>[];
    final queried = <String>{};
    while (_valid(live)) {
      final pending = live.presentations.keys
          .where((id) => !queried.contains(id))
          .toList();
      if (pending.isEmpty) break;
      for (final id in pending) {
        queried.add(id);
        try {
          final answers = await api.ownAnswers(live.lesson.id, id);
          if (!_valid(live)) return;
          live.answers.addAll(answers);
        } catch (failure) {
          known = false;
          failures.add(failure.toString());
        }
      }
    }
    if (!_valid(live)) return;
    live.answersKnown = known;
    live.syncingAnswers = false;
    live.answerSyncError = failures.isEmpty ? null : failures.join('\n');
    if (failures.isNotEmpty) logs.add(AppLogEvent.answers, success: false);
    live.draftAnswers.removeWhere((id, _) => live.answers.containsKey(id));
    for (final id in live.answers.keys) {
      _cancelAutomaticSubmission(live, id, message: '已读取提交记录');
    }
    try {
      await _persistAnswers(live);
    } catch (_) {
      live.error = '答案已读取，但未能保存到本机';
    }
    _notify();
    unawaited(_runAutomatic(live));
  }

  Future<void> submitAnswer(
    LiveClass live,
    Question question,
    dynamic answer,
  ) async {
    if (!_valid(live) || live.ended) throw const ApiFailure('课堂已结束或账号已退出');
    _cancelAutomaticSubmission(live, question.id);
    if (live.answers.containsKey(question.id)) throw const ApiFailure('这道题已提交');
    if (live.submitting.contains(question.id)) {
      throw const ApiFailure('这道题正在提交');
    }
    final latest = live.questions[question.id] ?? question;
    if (!live.activeProblemIds.contains(question.id) || !_inWindow(latest)) {
      throw const ApiFailure('答题时间已结束');
    }
    live.submitting.add(question.id);
    _notify();
    try {
      await api.submit(live.session, latest, answer);
      logs.add(AppLogEvent.submit, success: true);
      if (!_valid(live)) return;
      live.answers[question.id] = AnswerRecord(
        problemId: question.id,
        answer: answer,
        source: AnswerSource.local,
        submittedAt: DateTime.now().millisecondsSinceEpoch,
      );
      live.draftAnswers.remove(question.id);
      try {
        await _persistAnswers(live);
      } catch (_) {
        live.error = '提交已成功，但本机保存失败，请同步远端答案';
      }
    } catch (failure) {
      // A timed-out POST might have reached the server. Never retry it blindly.
      logs.add(AppLogEvent.submit, success: false);
      live.answersKnown = false;
      live.answerSyncError = '提交结果未确认，请先同步我的答案再决定是否重试';
      rethrow;
    } finally {
      live.submitting.remove(question.id);
      _notify();
    }
  }

  void _cancelAutomaticSubmission(
    LiveClass live,
    String id, {
    String? message,
  }) {
    final pending = live._automaticSubmissions.remove(id);
    pending?.timer?.cancel();
    if (pending != null && message != null) live.autoStates[id] = message;
  }

  void _cancelAutomaticSubmissions(LiveClass live, {String? message}) {
    for (final id in List.of(live._automaticSubmissions.keys)) {
      _cancelAutomaticSubmission(live, id, message: message);
    }
  }

  /// A user's edit invalidates both a queued submission and an earlier AI result.
  /// Keep the editable answer so rebuilding a card cannot restore the old result.
  void updateAnswerDraft(LiveClass live, Question question, dynamic answer) {
    if (!_valid(live) || live.answers.containsKey(question.id)) return;
    live._editedDrafts.add(question.id);
    live.draftAnswers[question.id] = answer;
    _cancelAutomaticSubmission(live, question.id);
    live.autoStates[question.id] = '答案已修改，待确认提交';
    _notify();
  }

  bool _automaticSubmissionValid(LiveClass live, _AutomaticSubmission job) {
    final id = job.question.id;
    return _valid(live) &&
        identical(live._automaticSubmissions[id], job) &&
        job.generation == _generation &&
        settings.autoAnswer &&
        settings.autoSubmit &&
        job.settingsSnapshot == jsonEncode(settings.toJson()) &&
        !live.ended &&
        live.answersKnown &&
        !live.syncingAnswers &&
        !live.answers.containsKey(id) &&
        !live.submitting.contains(id) &&
        !live._editedDrafts.contains(id) &&
        live.activeProblemIds.contains(id) &&
        live.questions[id]?.dt == job.question.dt &&
        _inWindow(live.questions[id] ?? job.question) &&
        jsonEncode(live.draftAnswers[id]) == jsonEncode(job.answer);
  }

  void _scheduleAutomaticSubmission(
    LiveClass live,
    Question question,
    dynamic answer,
    int generation,
    String settingsSnapshot,
    int delaySeconds,
  ) {
    final id = question.id;
    final current = live.questions[id] ?? question;
    if (current.limit > 0 &&
        DateTime.now().millisecondsSinceEpoch +
                current.serverOffsetMillis +
                delaySeconds * 1000 >=
            current.dt + current.limit * 1000) {
      live.autoStates[id] = '答题剩余时间不足，已取消自动提交';
      return;
    }
    _cancelAutomaticSubmission(live, id);
    final job = _AutomaticSubmission(
      generation: generation,
      settingsSnapshot: settingsSnapshot,
      question: question,
      answer: answer,
    );
    live._automaticSubmissions[id] = job;
    live.autoStates[id] = '答案已填充，$delaySeconds 秒后自动提交';
    job.timer = Timer(Duration(seconds: delaySeconds), () {
      unawaited(_submitAutomatic(live, job));
    });
  }

  Future<void> _submitAutomatic(
    LiveClass live,
    _AutomaticSubmission job,
  ) async {
    final id = job.question.id;
    var posting = false;
    try {
      if (!_automaticSubmissionValid(live, job)) {
        if (identical(live._automaticSubmissions[id], job)) {
          live.autoStates[id] = '课堂或设置已变化，已取消自动提交';
        }
        return;
      }
      // Waiting gives other clients time to submit; query again just before POST.
      final deck = live.presentations.values
          .where((deck) => deck.slides.any((slide) => slide.question?.id == id))
          .firstOrNull;
      if (deck != null) {
        final remote = await api.ownAnswers(live.lesson.id, deck.id);
        if (!_automaticSubmissionValid(live, job)) return;
        live.answers.addAll(remote);
        if (live.answers.containsKey(id)) {
          live.draftAnswers.remove(id);
          live.autoStates[id] = '已读取提交记录';
          await _persistAnswers(live);
          return;
        }
      }
      if (!_automaticSubmissionValid(live, job)) {
        if (identical(live._automaticSubmissions[id], job)) {
          live.autoStates[id] = '课堂或设置已变化，已取消自动提交';
        }
        return;
      }
      posting = true;
      live.autoStates[id] = '正在自动提交';
      await submitAnswer(live, job.question, job.answer);
      if (_valid(live)) live.autoStates[id] = '已自动提交';
    } catch (failure) {
      logs.add(AppLogEvent.automatic, success: false);
      if (_valid(live) &&
          (identical(live._automaticSubmissions[id], job) ||
              posting &&
                  !live._editedDrafts.contains(id) &&
                  job.settingsSnapshot == jsonEncode(settings.toJson()) &&
                  live.questions[id]?.dt == job.question.dt)) {
        live.autoStates[id] = '自动答题未完成：$failure';
      }
    } finally {
      if (identical(live._automaticSubmissions[id], job)) {
        live._automaticSubmissions.remove(id);
      }
      if (_valid(live)) _notify();
    }
  }

  Future<void> _runAutomatic(LiveClass live) async {
    if (!_valid(live) || live.ended || !settings.autoAnswer) return;
    if (!live.answersKnown || live.syncingAnswers) {
      for (final id in live.activeProblemIds) {
        if (!live.answers.containsKey(id)) {
          live.autoStates[id] = '作答状态未同步，暂停自动提交';
        }
      }
      _notify();
      return;
    }
    for (final id in List.of(live.activeProblemIds)) {
      final question = live.questions[id];
      if (question == null ||
          !_inWindow(question) ||
          live._editedDrafts.contains(id) ||
          live.answers.containsKey(id) ||
          live.submitting.contains(id)) {
        continue;
      }
      final attempt = '$id:${question.dt}';
      if (!live.automaticAttempts.add(attempt)) continue;
      final generation = _generation;
      final settingsSnapshot = jsonEncode(settings.toJson());
      live.autoStates[id] = settings.answerMode == AnswerMode.ai
          ? 'AI 正在作答'
          : '正在自动作答';
      _notify();
      try {
        final snapshot = AppSettings.fromJson(settings.toJson());
        final fixed = snapshot.fixedAnswerFor(question);
        if (snapshot.answerMode == AnswerMode.fixed &&
            (fixed == null || fixed.trim().isEmpty)) {
          live.autoStates[id] = fixed == null
              ? '暂不支持此题型自动答题'
              : '未设置此题型固定答案，已跳过';
          _notify();
          continue;
        }
        logs.add(AppLogEvent.automatic);
        String result = fixed ?? '';
        if (snapshot.answerMode == AnswerMode.ai) {
          final presentation = live.presentations.values
              .where(
                (deck) => deck.slides.any((slide) => slide.question?.id == id),
              )
              .firstOrNull;
          final page =
              presentation?.slides.indexWhere(
                (slide) => slide.question?.id == id,
              ) ??
              -1;
          final slides = AiAnswerService.selectedSlides(
            presentation,
            page,
            snapshot.slideScope,
          );
          result = await ai.generate(
            settings: snapshot,
            question: question,
            slides: slides,
            loadImage: loadImage,
          );
        }
        if (!_valid(live) ||
            generation != _generation ||
            !settings.autoAnswer ||
            settingsSnapshot != jsonEncode(settings.toJson()) ||
            live.ended ||
            !_inWindow(live.questions[id] ?? question) ||
            live.questions[id]?.dt != question.dt) {
          live.autoStates[id] = '课堂或设置已变化，已取消自动提交';
          continue;
        }
        if (live._editedDrafts.contains(id)) {
          live.autoStates[id] = '答案已修改，待确认提交';
          continue;
        }
        final parsed = AiAnswerService.parse(result, question);
        // An official client may have submitted while AI was running.
        final deck = live.presentations.values
            .where(
              (deck) => deck.slides.any((slide) => slide.question?.id == id),
            )
            .firstOrNull;
        if (deck != null) {
          final remote = await api.ownAnswers(live.lesson.id, deck.id);
          if (!_valid(live)) return;
          live.answers.addAll(remote);
        }
        if (live.answers.containsKey(id)) {
          live.autoStates[id] = '已读取提交记录';
          continue;
        }
        if (live._editedDrafts.contains(id)) {
          live.autoStates[id] = '答案已修改，待确认提交';
          continue;
        }
        if (!settings.autoAnswer ||
            settingsSnapshot != jsonEncode(settings.toJson()) ||
            live.questions[id]?.dt != question.dt) {
          continue;
        }
        if (!_valid(live) ||
            live.ended ||
            !live.activeProblemIds.contains(id) ||
            !_inWindow(live.questions[id] ?? question)) {
          continue;
        }
        live.draftAnswers[id] = parsed;
        logs.add(AppLogEvent.draft, success: true);
        if (settings.autoSubmit) {
          _scheduleAutomaticSubmission(
            live,
            question,
            parsed,
            generation,
            settingsSnapshot,
            snapshot.autoSubmitDelaySeconds,
          );
        } else {
          live.autoStates[id] = '答案已填充，待确认提交';
        }
      } catch (failure) {
        logs.add(AppLogEvent.automatic, success: false);
        if (_valid(live) &&
            generation == _generation &&
            settingsSnapshot == jsonEncode(settings.toJson()) &&
            live.questions[id]?.dt == question.dt &&
            !live.ended &&
            live.activeProblemIds.contains(id) &&
            !live._editedDrafts.contains(id) &&
            !live.answers.containsKey(id)) {
          live.autoStates[id] = '自动答题未完成：$failure';
        }
      }
      _notify();
    }
  }

  final Map<String, Map<String, AnswerRecord>> _persistedAnswers = {};
  Future<void> _restoreAnswers() async {
    final id = account?.id;
    final generation = _generation;
    if (id == null) return;
    final raw = await store.read('answers:$id');
    if (generation != _generation || account?.id != id || _disposed) return;
    _persistedAnswers.clear();
    if (raw == null) return;
    final data = object(jsonDecode(raw));
    for (final entry in data.entries) {
      final answers = <String, AnswerRecord>{};
      for (final value in array(entry.value)) {
        final answer = AnswerRecord.fromJson(object(value));
        answers[answer.problemId] = answer;
      }
      _persistedAnswers[entry.key] = answers;
    }
  }

  Future<void> _persistAnswers(LiveClass live) async {
    if (!_valid(live)) return;
    _persistedAnswers[live.lesson.id] = Map.of(live.answers);
    // Keep a bounded account-scoped journal in platform secure storage.
    while (_persistedAnswers.length > 80) {
      _persistedAnswers.remove(_persistedAnswers.keys.first);
    }
    await _write(
      'answers:${live.session.userId}',
      jsonEncode(
        _persistedAnswers.map(
          (key, value) => MapEntry(
            key,
            value.values.map((answer) => answer.toJson()).toList(),
          ),
        ),
      ),
    );
  }

  Future<void> syncAttendance(LiveClass live) async {
    if (!_valid(live) || live.syncingAttendance) return;
    live.syncingAttendance = true;
    live.attendanceError = null;
    try {
      final status = await loadAttendance(live.lesson);
      if (!_valid(live)) return;
      live.attendance = status;
    } catch (_) {
      if (!_valid(live)) return;
      live.attendance = AttendanceStatus.unknown;
      live.attendanceError = '签到状态暂时无法获取';
    } finally {
      live.syncingAttendance = false;
      if (_valid(live)) _notify();
    }
  }

  Future<LocationCheckin> locationStatus(LiveClass live) async {
    if (!_valid(live) || live.ended) throw const ApiFailure('课堂已结束或账号已退出');
    final status = await api.locationStatus(live.session);
    if (_valid(live)) {
      live.location = status;
      _notify();
    }
    return status;
  }

  Future<bool> confirmLocation(
    LiveClass live,
    LocationCheckin confirmed,
  ) async {
    if (!_valid(live) || live.ended) throw const ApiFailure('课堂已结束或账号已退出');
    final success = await _logged(
      AppLogEvent.location,
      () => api.locationSubmit(live.session, confirmed),
    );
    if (_valid(live)) {
      live.location = await api.locationStatus(live.session);
      _notify();
    }
    if (_valid(live)) unawaited(syncAttendance(live));
    return success;
  }

  Future<Json> uploadAnswerImage(LiveClass live, String path) {
    if (!_valid(live) || live.ended) throw const ApiFailure('课堂已结束或账号已退出');
    return api.uploadImage(live.session, path);
  }

  Future<void> refreshClassroom(LiveClass live) async {
    if (!_valid(live)) throw const ApiFailure('账号已退出');
    live.error = null;
    final id = live.presentationId;
    if (id != null) {
      live.presentations.remove(id);
      await _showPresentation(live, id);
    }
    if (!live.ended) await live.connection?.reconnect();
    await syncAnswers(live);
    await syncAttendance(live);
    _notify();
  }

  Future<Uint8List> loadImage(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const ApiFailure('课件图片地址无效');
    }
    // A dedicated client has no Rain Classroom Cookie or AI Authorization.
    final response = await _media.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) throw const ApiFailure('课件图片下载失败');
    return Uint8List.fromList(bytes);
  }

  Future<void> exportSlides(
    Presentation deck, {
    required bool pptx,
    Rect? sharePositionOrigin,
  }) async {
    await _logged(AppLogEvent.export, () async {
      final file = await SlideExporter(loadImage).export(deck, pptx: pptx);
      await FileExport().deliver(
        file,
        suggestedName: file.uri.pathSegments.last,
        extension: pptx ? 'pptx' : 'zip',
        mimeType: pptx
            ? 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
            : 'application/zip',
        sharePositionOrigin: sharePositionOrigin,
      );
    });
  }

  Future<void> saveSlide(Slide slide) async {
    await _logged(
      AppLogEvent.gallery,
      () => gallery.saveSlides([slide], loadImage),
    );
  }

  Future<int> saveSlidesToGallery(List<Slide> slides) =>
      _logged(AppLogEvent.gallery, () => gallery.saveSlides(slides, loadImage));

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _poller?.cancel();
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live);
      unawaited(live.connection?.close() ?? Future.value());
    }
    unawaited(background.setEnabled(false));
    _media.close();
    super.dispose();
  }
}
