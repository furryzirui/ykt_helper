import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../data/live_connection.dart';
import '../data/rain_api.dart';
import '../data/secure_store.dart';
import '../domain/models.dart';
import '../services/ai_answer.dart';
import '../services/app_logs.dart';
import '../services/app_autostart.dart';
import '../services/background_runtime.dart';
import '../services/classroom_notifications.dart';
import '../services/gallery_saver.dart';
import '../services/file_export.dart';
import '../services/slide_export.dart';

class _AutomaticSubmission {
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

class _PreparedAutomaticAnswer {
  final int generation, questionVersion;
  final String settingsSnapshot;
  final dynamic answer;
  const _PreparedAutomaticAnswer({
    required this.generation,
    required this.questionVersion,
    required this.settingsSnapshot,
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
  bool awaitingTimeline = false;
  String? error, answerSyncError, presentationId;
  int slideIndex = 0, teacherSlideIndex = 0;
  final Map<String, Presentation> presentations = {};
  final Map<String, Question> questions = {};
  final Set<String> activeProblemIds = {};
  final Map<String, AnswerRecord> answers = {};
  final Map<String, String> autoStates = {};
  final Set<String> submitting = {}, automaticAttempts = {};
  final Map<String, Object> _automaticAnswerFlights = {};
  final Map<String, String> _automaticSkipReasons = {};
  final Map<String, Json> launches = {};
  final Map<String, int> closedAtSequence = {};
  int eventSequence = 0;
  LocationCheckin? location;
  int _locationRevision = 0;
  bool _attendanceFromLocation = false;
  Future<void>? _locationCheckinFlight;
  AttendanceStatus attendance = AttendanceStatus.unknown;
  String? attendanceError;
  bool syncingAttendance = false;
  String get checkinText => attendance.label;
  final Map<String, dynamic> draftAnswers = {};
  final Map<String, _AutomaticSubmission> _automaticSubmissions = {};
  final Map<String, _PreparedAutomaticAnswer> _preparedAutomaticAnswers = {};
  final Map<String, int> _questionVersions = {};
  final Map<String, DateTime> _answerableSince = {};
  final Set<String> _timingConfirmed = {};
  final Map<String, Timer> _questionTimingTimers = {};
  final Set<String> _automaticSubmissionAttempts = {};
  Timer? _automaticQueueTimer;
  bool _automaticQueueRunning = false;
  DateTime? _lastSuccessfulSubmission;
  final Set<String> _observedSubmittedIds = {};
  final Set<String> _failedAutomaticQuestionIds = {};
  final Set<String> _automaticPostAttemptedRounds = {};
  bool _automaticSubmissionUncertain = false;
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

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  late final RainApi api;
  final KeyValueStore store;
  final AiAnswerService ai;
  final BackgroundRuntime background;
  final AppAutostart autostart;
  final GallerySaver gallery;
  final AppLogs logs;
  final ClassroomNotifications notifications;
  final Set<String> _attentionAttempts = {}, _activeAttention = {};
  final bool startTimers, connectSockets;
  final DateTime Function() now;
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
  DateTime? _serviceDeadline;
  bool _nativeDeadlineExpired = false, _serviceExpiryHandled = false;
  bool _windowsExitPending = false;
  int _automationEpoch = 0;
  DateTime? get serviceDeadline => _serviceDeadline;
  Duration? get serviceRemaining {
    final deadline = _serviceDeadline;
    if (deadline == null) return null;
    if (_nativeDeadlineExpired) return Duration.zero;
    final remaining = deadline.difference(now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool _foreground = true, _serviceTransition = false, _expiringService = false;
  int _lifecycleRevision = 0;
  Timer? _serviceTimer;
  bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  BackgroundServiceMode get _runtimeMode =>
      _ios ? settings.backgroundMode : BackgroundServiceMode.native;
  bool get _deadlineExpired =>
      _nativeDeadlineExpired ||
      _serviceDeadline != null && !_serviceDeadline!.isAfter(now());
  bool get _automaticAllowed =>
      !_disposed &&
      !_windowsExitPending &&
      (_windows || _foreground || background.enabled && !_deadlineExpired);
  // These controls are intentionally process-local. An explicit off action
  // wins over auto-start until the user explicitly turns the service on again.
  bool _serviceManuallyDisabled = false;
  bool _serviceManuallyEnabled = false;
  bool _nativeServiceStateUnknown = false;
  bool _resumeLoginPending = false;
  Future<void> _startupOperations = Future<void>.value();
  Future<void> _settingsOperations = Future<void>.value();
  Future<void> _backgroundOperations = Future<void>.value();
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
    ClassroomNotifications? notifications,
    this.startTimers = true,
    this.connectSockets = true,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       store = store ?? SecureStore(),
       ai = ai ?? AiAnswerService(),
       background = background ?? BackgroundRuntime(),
       autostart = autostart ?? const AppAutostart(),
       gallery = gallery ?? const GallerySaver(),
       logs = logs ?? AppLogs(),
       notifications = notifications ?? const ClassroomNotifications() {
    this.api =
        api ??
        RainApi(
          onCookiesChanged: (cookies) => _write('cookies', cookies),
          onRequestError: (path, method, failure, elapsed) => this.logs.add(
            AppLogEvent.api,
            success: false,
            error: failure,
            elapsed: elapsed,
            code: failure is ApiFailure ? failure.code : null,
            context: {'phase': 'request', 'route': path, 'method': method},
          ),
        );
    WidgetsBinding.instance.addObserver(this);
    this.background.setStateListener(_runtimeStateChanged);
  }
  void _notify() {
    if (!_disposed) {
      _syncQuestionNotifications();
      notifyListeners();
    }
  }

  void _syncQuestionNotifications() {
    final wanted = <String>{};
    if (!_foreground && !_disposed) {
      for (final live in classrooms.values) {
        if (!_valid(live) || live.ended) continue;
        for (final question in live.questions.values) {
          if (!canSubmitAnswer(live, question)) continue;
          final state = live.autoStates[question.id] ?? '';
          final failed =
              state.startsWith('自动答题未完成') ||
              state.startsWith('暂不支持') ||
              state.startsWith('未设置') ||
              state.startsWith('自动提交等待同步') ||
              state.contains('已取消自动提交') ||
              state.contains('等待补全') ||
              state.contains('等待修改');
          final kind = failed
              ? 'attention'
              : !settings.autoAnswer
              ? 'answer'
              : !settings.autoSubmit &&
                    live.draftAnswers.containsKey(question.id)
              ? 'submit'
              : null;
          if (kind == null) continue;
          final key =
              '${live.session.userId}:${live.lesson.id}:${question.id}:${question.dt}:$kind';
          wanted.add(key);
          if (!_attentionAttempts.add(key)) continue;
          _activeAttention.add(key);
          final generation = _generation;
          unawaited(
            _showQuestionNotification(
              live,
              question,
              key,
              generation,
              failed
                  ? '题目需要手动处理，请打开课堂检查'
                  : kind == 'submit'
                  ? '答案已填充，请打开课堂确认提交'
                  : '有题目需要手动作答，请打开课堂',
            ),
          );
        }
      }
    }
    for (final key in _activeAttention.difference(wanted).toList()) {
      _activeAttention.remove(key);
      unawaited(notifications.cancel(key));
    }
  }

  Future<void> _showQuestionNotification(
    LiveClass live,
    Question question,
    String key,
    int generation,
    String body,
  ) async {
    try {
      final delivered = await notifications.show(
        key: key,
        title: live.lesson.title,
        body: body,
        lessonId: live.lesson.id,
        problemId: question.id,
      );
      if (!delivered && generation == _generation && _valid(live)) {
        _attentionAttempts.remove(key);
        _activeAttention.remove(key);
      }
      if (_foreground ||
          _disposed ||
          generation != _generation ||
          !_valid(live) ||
          !_activeAttention.contains(key) ||
          !canSubmitAnswer(live, question)) {
        await notifications.cancel(key);
      }
    } catch (_) {
      // Local notification delivery must not affect signing in or answering.
    }
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setForeground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      setForeground(false);
    }
  }

  /// Headless Android startup supplies this before initialize().
  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (foreground && _windows) _windowsExitPending = false;
    final revision = ++_lifecycleRevision;
    if (_deadlineExpired) unawaited(_expireService());
    if (!_automaticAllowed) {
      _pauseClassroomWork();
    } else if (foreground && initialized) {
      unawaited(_resumeClassroomWork(revision));
    }
    _syncQuestionNotifications();
  }

  void _pauseClassroomWork() {
    _automationEpoch++;
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live, message: '后台服务已关闭，返回前台后继续');
      live.automaticAttempts.clear();
      live._automaticSubmissionAttempts.clear();
      live._failedAutomaticQuestionIds.clear();
      live._answerableSince.clear();
      for (final timer in live._questionTimingTimers.values) {
        timer.cancel();
      }
      live._questionTimingTimers.clear();
      live.activeProblemIds.clear();
      live.awaitingTimeline = connectSockets;
      unawaited(live.connection?.close() ?? Future<void>.value());
    }
  }

  Future<void> _resumeClassroomWork(int revision) async {
    if (!_automaticAllowed || revision != _lifecycleRevision || _disposed) {
      return;
    }
    _automationEpoch++;
    final state = await background.status();
    if (state != null) _runtimeStateChanged(state);
    if (_deadlineExpired) await _expireService();
    if (!_automaticAllowed || revision != _lifecycleRevision || _disposed) {
      return;
    }
    for (final live in List.of(classrooms.values)) {
      if (live.ended) continue;
      _cancelAutomaticSubmissions(live, message: '正在同步课堂状态');
      live.automaticAttempts.clear();
      live._automaticSubmissionAttempts.clear();
      live._answerableSince.clear();
      for (final timer in live._questionTimingTimers.values) {
        timer.cancel();
      }
      live._questionTimingTimers.clear();
      // A queued pre-suspension timer must not submit before the server state
      // has been read again. Timeline replay determines current active tasks.
      live.answersKnown = false;
      live.activeProblemIds.clear();
      live.awaitingTimeline = connectSockets;
      await live.connection?.reconnect();
      if (!_automaticAllowed ||
          revision != _lifecycleRevision ||
          !_valid(live)) {
        return;
      }
      await syncAnswers(live);
      unawaited(syncAttendance(live));
    }
    if (_automaticAllowed && revision == _lifecycleRevision) {
      await retryBackground();
      await refresh();
    }
  }

  Future<void> _restoreServiceSession() async {
    if (settings.autoStartService && settings.serviceTimeoutMinutes != 0) {
      final next = AppSettings.fromJson(settings.toJson())
        ..serviceTimeoutMinutes = 0;
      await _write('settings', jsonEncode(next.toJson()));
      settings = next;
    }
    if (_windows) {
      // A desktop process launch is a new session, including login startup.
      await _resetServiceTimeout();
      return;
    }
    if (settings.autoStartService) {
      // Migrate older installations that allowed both options. Removing an
      // obsolete deadline never starts a service or assumes it is running.
      await background.configure(mode: _runtimeMode, deadline: null);
    }
    final native = await background.status();
    if (native == null) {
      // A failed status read is neither a stopped service nor permission to
      // replace its timer. Wait for a known status or an explicit stop/start.
      _nativeServiceStateUnknown = true;
      return;
    }
    await _adoptNativeServiceSession(native);
  }

  Future<void> _adoptNativeServiceSession(BackgroundRuntimeState native) async {
    _nativeServiceStateUnknown = false;
    if (!native.enabled) {
      // The previous timer belongs to the previous service, never the next
      // automatic/manual start. A surviving native service remains authoritative.
      await _resetServiceTimeout();
      return;
    }
    if (settings.autoStartService) {
      _serviceManuallyEnabled = true;
      await _resetServiceTimeout();
      await background.configure(mode: _runtimeMode, deadline: null);
      return;
    }
    _serviceDeadline = native.deadline;
    _serviceManuallyEnabled = true;
    _nativeDeadlineExpired = native.reason == 'deadline';
    if (_serviceDeadline == null && settings.serviceTimeoutMinutes != 0) {
      final next = AppSettings.fromJson(settings.toJson())
        ..serviceTimeoutMinutes = 0;
      await _write('settings', jsonEncode(next.toJson()));
      settings = next;
    }
    if (_deadlineExpired) {
      _serviceManuallyDisabled = true;
      await autostart.setSuspended(true);
    }
    await _persistServiceSession();
    _armServiceTimer();
  }

  void _clearServiceTimeoutState() {
    _serviceTimer?.cancel();
    _serviceTimer = null;
    _serviceDeadline = null;
    _nativeDeadlineExpired = false;
    _serviceExpiryHandled = false;
    _windowsExitPending = false;
  }

  Future<void> _resetServiceTimeout() async {
    _clearServiceTimeoutState();
    if (settings.serviceTimeoutMinutes != 0) {
      final next = AppSettings.fromJson(settings.toJson())
        ..serviceTimeoutMinutes = 0;
      await _write('settings', jsonEncode(next.toJson()));
      settings = next;
    }
    await _persistServiceSession();
  }

  Future<void> _persistServiceSession() => _write(
    'serviceSession',
    jsonEncode({
      'deadlineEpochMs': _serviceDeadline?.millisecondsSinceEpoch,
      'expired': _deadlineExpired,
    }),
  );

  void _armServiceTimer() {
    _serviceTimer?.cancel();
    _serviceTimer = null;
    final deadline = _serviceDeadline;
    if (deadline == null || _disposed || _serviceExpiryHandled) return;
    final remaining = deadline.difference(now());
    _serviceTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _nativeDeadlineExpired = true;
      unawaited(_expireService());
    });
  }

  Future<void> setServiceTimeout(int minutes) async {
    if (!serviceTimeoutOptions.contains(minutes)) {
      throw const ApiFailure('无法识别定时关闭选项');
    }
    if (minutes != 0 && settings.autoStartService) {
      throw const ApiFailure('请先关闭自动启动服务，再设置定时关闭');
    }
    final next = AppSettings.fromJson(settings.toJson())
      ..serviceTimeoutMinutes = minutes;
    await saveSettings(next);
    if (_disposed) return;
    if (settings.autoStartService) return;
    if (_windows || backgroundEnabled) {
      _nativeDeadlineExpired = false;
      _serviceExpiryHandled = false;
      _windowsExitPending = false;
      _serviceDeadline = minutes == 0
          ? null
          : now().add(Duration(minutes: minutes));
      await _persistServiceSession();
      await background.configure(
        mode: _runtimeMode,
        deadline: _serviceDeadline,
      );
      _armServiceTimer();
      _notify();
    }
  }

  Future<void> _expireService() async {
    if (settings.autoStartService) {
      // A callback queued before the preference changed no longer owns a
      // valid finite timer. It must not suspend the unlimited service.
      _clearServiceTimeoutState();
      return;
    }
    if (_disposed ||
        _expiringService ||
        _serviceExpiryHandled ||
        !_deadlineExpired) {
      return;
    }
    _expiringService = true;
    _serviceTimer?.cancel();
    _serviceExpiryHandled = true;
    if (_windows && _foreground) {
      // This deadline applies to the state at expiry; moving to the tray later
      // must not retroactively turn a foreground no-op into an app exit.
      _expiringService = false;
      _notify();
      return;
    }
    _windowsExitPending = _windows;
    _serviceManuallyDisabled = true;
    _serviceManuallyEnabled = false;
    try {
      await autostart.setSuspended(true);
      await background.setEnabled(false);
      await _persistServiceSession();
      if (!_automaticAllowed) _pauseClassroomWork();
      if (!_foreground && !_ios) {
        for (final live in classrooms.values) {
          _cancelAutomaticSubmissions(live, message: '定时关闭已到期');
          await live.connection?.close();
        }
        await _writes;
        if (!_foreground) await background.exitApplication();
      }
      backgroundWarning = null;
    } catch (failure) {
      backgroundWarning = failure is ApiFailure
          ? failure.message
          : '定时关闭未完成，请手动关闭';
      logs.add(
        AppLogEvent.background,
        success: false,
        error: failure,
        context: const {'phase': 'serviceDeadline'},
      );
    } finally {
      _expiringService = false;
      _notify();
    }
  }

  void _runtimeStateChanged(BackgroundRuntimeState state) {
    if (_disposed) return;
    if (_serviceTransition || _expiringService) return;
    if (state.reason == 'deadline' && settings.autoStartService) {
      // The former native deadline may fire while the unlimited preference
      // is being persisted. Preserve an earlier deliberate manual stop.
      _clearServiceTimeoutState();
      if (!_serviceManuallyDisabled) {
        unawaited(
          autostart
              .setSuspended(false)
              .then((_) async {
                if (!_disposed &&
                    settings.autoStartService &&
                    !_serviceManuallyDisabled) {
                  await _updateBackground();
                }
              })
              .catchError((Object failure) {
                logs.add(
                  AppLogEvent.background,
                  success: false,
                  error: failure,
                  context: const {'phase': 'restoreUnlimitedService'},
                );
              }),
        );
      }
      return;
    }
    if (state.enabled &&
        state.deadline == null &&
        (_serviceDeadline != null || settings.serviceTimeoutMinutes != 0)) {
      // Android can recreate its service while the shared Flutter engine
      // survives. The native unlimited session replaces the old Dart timer.
      unawaited(
        _resetServiceTimeout().then((_) => _notify()).catchError((
          Object failure,
        ) {
          logs.add(
            AppLogEvent.background,
            success: false,
            error: failure,
            context: const {'phase': 'resetServiceTimer'},
          );
        }),
      );
    }
    if (state.reason == 'deadline' || _deadlineExpired) {
      _nativeDeadlineExpired = true;
      _serviceDeadline = state.deadline ?? _serviceDeadline ?? now();
      unawaited(_expireService());
    } else if (!state.enabled &&
        state.reason != null &&
        state.reason != 'stopped') {
      _serviceManuallyDisabled = true;
      _serviceManuallyEnabled = false;
      backgroundWarning = state.message ?? '后台服务已停止，请返回设置重新开启';
      unawaited(autostart.setSuspended(true).catchError((Object _) {}));
      if (!_automaticAllowed) _pauseClassroomWork();
      _notify();
    }
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
        logs.protectSecrets([settings.apiKey]);
        // The unified check-in switch now also submits location check-ins.
        // Existing ordinary-only consent must not silently enable that action.
        if (settings.autoEnter && !settings.autoLocationCheckin) {
          settings.autoEnter = false;
          if (!settings.autoAnswer) {
            settings.autoStartService = false;
            settings.appAutoStart = false;
          }
          await _write('settings', jsonEncode(settings.toJson()));
          logs.add(
            AppLogEvent.settings,
            success: true,
            detail: '自动签到已合并位置签到，请重新开启并确认',
            context: const {'phase': 'migrateCheckinConsent'},
          );
        }
      }
      await _restoreServiceSession();
      if (_disposed || generation != _generation) return;
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
      logs.add(
        AppLogEvent.startup,
        success: false,
        error: failure,
        context: const {'phase': 'restoreSettingsAndAccount'},
      );
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
        if (busy || _disposed || !_automaticAllowed) return;
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
      for (final timer in live._questionTimingTimers.values) {
        timer.cancel();
      }
      live._questionTimingTimers.clear();
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
    _attentionAttempts.clear();
    _activeAttention.clear();
    unawaited(notifications.cancelAll());
    _resumeLoginPending = false;
    await background.setEnabled(false);
    _serviceTimer?.cancel();
    _serviceDeadline = null;
    _nativeDeadlineExpired = false;
    _serviceExpiryHandled = false;
    _windowsExitPending = false;
    await _persistServiceSession();
    try {
      await _configureAppAutostart(settings);
    } catch (failure) {
      // Never let OS registration failure leave a logged-out account active.
      logs.add(
        AppLogEvent.background,
        success: false,
        error: failure,
        context: const {'phase': 'disableAutostartAfterLogout'},
      );
    }
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live);
      for (final timer in live._questionTimingTimers.values) {
        timer.cancel();
      }
      live._questionTimingTimers.clear();
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
      logs.add(
        AppLogEvent.refresh,
        success: false,
        count: failures.length,
        error: ApiFailure(failures.join('\n')),
        context: const {'phase': 'loadCoursesAndLiveLessons'},
      );
    }
    busy = false;
    _notify();
    if (settings.autoEnter && _automaticAllowed) {
      for (final lesson in List.of(liveLessons)) {
        if (!_automaticAllowed) break;
        if (classrooms[lesson.id]?.ended == true ||
            classrooms.containsKey(lesson.id)) {
          continue;
        }
        try {
          await enter(lesson, automatic: true);
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
    final snapshot = AppSettings.fromJson(input.toJson());
    final operation = _settingsOperations
        .catchError((Object _) {})
        .then((_) => _saveSettings(snapshot));
    _settingsOperations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _saveSettings(AppSettings input) async {
    if (_disposed) return;
    final previousAnswerSettings = _automaticAnswerSettings(settings);
    final candidate = AppSettings.fromJson(input.toJson());
    logs.protectSecrets([candidate.apiKey]);
    if (!candidate.autoEnter) candidate.autoLocationCheckin = false;
    // Auto-start has no useful meaning without an automation trigger. This
    // normalization also lets users turn the last automation off cleanly.
    if (!candidate.autoEnter && !candidate.autoAnswer) {
      candidate.autoStartService = false;
      candidate.appAutoStart = false;
    }
    if (candidate.autoStartService) candidate.serviceTimeoutMinutes = 0;
    if (!autostart.supported ||
        backgroundSupported && !candidate.autoStartService) {
      candidate.appAutoStart = false;
    }
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        candidate.appAutoStart &&
        !settings.appAutoStart) {
      String? startupPermission;
      try {
        startupPermission = await autostart.permissionStatus();
      } catch (_) {
        // Unknown system formats/read failures do not imply explicit denial.
        // Native configuration still checks the registered startup command.
      }
      if (startupPermission == 'denied') {
        throw const ApiFailure('系统已禁用自启动，请在应用权限中允许');
      }
    }
    try {
      await _write('settings', jsonEncode(candidate.toJson()));
    } catch (failure) {
      logs.add(
        AppLogEvent.settings,
        success: false,
        error: failure,
        context: const {'phase': 'persistSettings'},
      );
      rethrow;
    }
    if (_disposed) return;
    settings = candidate;
    if (candidate.autoStartService) {
      await _resetServiceTimeout();
      try {
        await background.configure(mode: _runtimeMode, deadline: null);
      } catch (failure) {
        logs.add(
          AppLogEvent.background,
          success: false,
          error: failure,
          context: const {'phase': 'configureUnlimitedService'},
        );
      }
    }
    if (!candidate.autoEnter && !candidate.autoAnswer && !_windows) {
      _serviceTimer?.cancel();
      _serviceDeadline = null;
      _nativeDeadlineExpired = false;
      _serviceExpiryHandled = false;
      await _persistServiceSession();
    }
    logs.add(
      AppLogEvent.settings,
      success: true,
      detail: '设置已写入本机，后台服务状态另行记录',
      context: const {'phase': 'persistedSettings'},
    );
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live, message: '设置已变化，已取消自动提交');
      if (previousAnswerSettings != _automaticAnswerSettings(candidate) ||
          !candidate.autoAnswer) {
        live.automaticAttempts.clear();
        live._automaticAnswerFlights.clear();
      }
      live._automaticSubmissionAttempts.clear();
    }
    await _updateBackground();
    _notify();
    if (account != null) unawaited(refresh());
    for (final live in List.of(classrooms.values)) {
      unawaited(_runAutomatic(live));
      unawaited(_runAutomaticLocationCheckin(live));
    }
  }

  Future<void> retryBackground() => _updateBackground();

  /// Explicitly enables or disables the classroom service from Settings.
  /// Disabling it suppresses auto-start until an explicit re-enable, so
  /// refreshes and classroom events cannot surprise the user by restarting it.
  Future<void> setSystemService(
    bool enabled, {
    bool iosConfirmed = false,
  }) async {
    if (!enabled && settings.autoStartService) {
      throw const ApiFailure('请先关闭自动启动服务，再关闭系统服务');
    }
    if (!backgroundSupported) return;
    if (enabled && !(settings.autoEnter || settings.autoAnswer)) {
      throw const ApiFailure('请先开启至少一项自动化');
    }
    if (enabled && account == null) throw const ApiFailure('请先登录');
    if (enabled && _ios && !iosConfirmed) {
      throw const ApiFailure('请先确认 iOS 后台运行限制');
    }
    if (_nativeServiceStateUnknown) {
      if (!await background.setEnabled(false)) {
        throw const ApiFailure('无法停止状态未知的后台服务，请稍后重试');
      }
      _nativeServiceStateUnknown = false;
    }
    if (enabled && _ios) {
      final candidate = AppSettings.fromJson(settings.toJson())
        ..iosBackgroundConsentMode = settings.backgroundMode.name;
      await _write('settings', jsonEncode(candidate.toJson()));
      settings = candidate;
    }
    if (enabled && (!background.enabled || _deadlineExpired)) {
      await _resetServiceTimeout();
    } else if (!enabled) {
      _serviceTimer?.cancel();
      _serviceTimer = null;
      _serviceDeadline = null;
      _nativeDeadlineExpired = false;
      _serviceExpiryHandled = false;
      _windowsExitPending = false;
      await _persistServiceSession();
    }
    await autostart.setSuspended(!enabled);
    _serviceManuallyDisabled = !enabled;
    _serviceManuallyEnabled = enabled;
    _notify();
    await _updateBackground();
    if (!enabled && !_automaticAllowed) _pauseClassroomWork();
  }

  Future<void> _configureAppAutostart(AppSettings value) {
    final enabled = value.appAutoStart;
    final existingPreference = settings.appAutoStart && enabled;
    final eligible =
        (account != null || _resumeLoginPending) &&
        (value.autoEnter || value.autoAnswer) &&
        (!backgroundSupported || value.autoStartService) &&
        !_serviceManuallyDisabled;
    final operation = _startupOperations.catchError((Object _) {}).then((
      _,
    ) async {
      var canRun = eligible;
      // A revoked OS permission must not prevent unrelated edits or turning
      // automation off. Keep the saved preference, with native work stopped.
      // A newly enabled preference still reaches the native denial check.
      if (existingPreference &&
          eligible &&
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.windows) {
        try {
          if (await autostart.permissionStatus() == 'denied') canRun = false;
        } catch (_) {
          // Unknown status is allowed by the selected Windows policy.
        }
      }
      await autostart.configure(enabled: enabled, eligible: canRun);
    });
    _startupOperations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _updateBackground() {
    final operation = _backgroundOperations
        .catchError((Object _) {})
        .then((_) => _performUpdateBackground());
    _backgroundOperations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _performUpdateBackground() async {
    if (_disposed) return;
    final revision = ++_backgroundRevision;
    if (_nativeServiceStateUnknown) {
      final native = await background.status();
      if (_disposed || revision != _backgroundRevision) return;
      if (native == null) {
        backgroundWarning = '暂时无法确认后台服务状态，请稍后重试或手动重新开启';
        _notify();
        return;
      }
      await _adoptNativeServiceSession(native);
    }
    String? startupWarning;
    try {
      await _configureAppAutostart(settings);
    } catch (failure) {
      startupWarning = '应用自启动设置失败，请重新保存自动化设置';
      logs.add(
        AppLogEvent.background,
        success: false,
        error: failure,
        context: const {'phase': 'configureAppAutostart'},
      );
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
        !_deadlineExpired &&
        (!_ios ||
            settings.iosBackgroundConsentMode ==
                settings.backgroundMode.name) &&
        (_serviceManuallyEnabled || autoRequested);
    var okay = false;
    _serviceTransition = true;
    try {
      if (needed && !background.enabled) {
        await _resetServiceTimeout();
      }
      await background.configure(
        mode: _runtimeMode,
        deadline: _serviceDeadline,
      );
      okay = await background.setEnabled(needed);
    } catch (failure) {
      // Settings are already durable; a platform service failure is reported
      // independently and must not turn a successful local save into a failure.
      logs.add(
        AppLogEvent.background,
        success: false,
        error: failure,
        context: const {'phase': 'configureBackgroundRuntime'},
      );
    } finally {
      _serviceTransition = false;
    }
    if (_disposed || revision != _backgroundRevision) return;
    final previousWarning = backgroundWarning;
    backgroundWarning =
        startupWarning ??
        (_ios &&
                autoRequested &&
                !needed &&
                !_serviceManuallyDisabled &&
                settings.iosBackgroundConsentMode !=
                    settings.backgroundMode.name
            ? '请手动开启服务并确认 iOS 后台运行限制'
            : needed && !okay
            ? defaultTargetPlatform == TargetPlatform.iOS
                  ? background.failureMessage ??
                        (background.failureReason == 'locationPermission'
                            ? '请在应用权限中允许始终访问定位'
                            : '后台服务未能开启，请检查所选方案及权限后重试')
                  : '后台运行未开启，请在应用权限中允许通知和后台运行；当前仅能保证前台处理课堂。'
            : null);
    if (previousWarning != backgroundWarning || needed && okay) {
      logs.add(
        AppLogEvent.background,
        success: okay,
        detail: backgroundWarning ?? (needed ? '后台服务已运行' : '当前不需要后台服务'),
        context: {
          'phase': 'backgroundState',
          'enabled': background.enabled,
          'requested': needed,
          'mode': settings.backgroundMode.name,
        },
      );
    }
    _notify();
  }

  Future<LessonPage> loadLessons(Course course, int page) async {
    final generation = _generation;
    final accountId = account?.id;
    // The class may have started since the home screen's last refresh. Keep
    // history available when the live-list request fails, using known state.
    final latestLive = page == 0 && accountId != null
        ? api
              .liveLessons()
              .then<List<Lesson>?>((lessons) => lessons)
              .catchError((Object _) => null)
        : Future<List<Lesson>?>.value(null);
    final result = await _logged(
      AppLogEvent.lessons,
      () => api.lessons(course, page),
    );
    final latest = await latestLive;
    if (_disposed || generation != _generation || account?.id != accountId) {
      throw const ApiFailure('账号已变化，请重新打开课程');
    }
    if (latest != null &&
        !_disposed &&
        generation == _generation &&
        account?.id == accountId) {
      liveLessons = latest;
      courses = courses
          .map(
            (item) => item.withLive(
              latest
                  .where(
                    (lesson) =>
                        lesson.courseId == item.courseId &&
                        lesson.classroomId == item.classroomId,
                  )
                  .map((lesson) => lesson.id)
                  .toList(),
            ),
          )
          .toList();
      _notify();
    }
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
    final watch = Stopwatch()..start();
    try {
      final result = await action();
      logs.add(
        event,
        success: result is bool ? result : true,
        elapsed: watch.elapsed,
        detail: result == false ? '操作已取消或未完成' : null,
        count: result is List
            ? result.length
            : result is int
            ? result
            : null,
        context: const {'phase': 'completed'},
      );
      return result;
    } catch (error) {
      logs.add(
        event,
        success: false,
        error: error,
        elapsed: watch.elapsed,
        context: const {'phase': 'failed'},
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

  Future<AttendanceStatus> loadAttendance(Lesson lesson) {
    final live = classrooms[lesson.id];
    if (live != null &&
        _valid(live) &&
        live.lesson.courseId == lesson.courseId &&
        live.lesson.classroomId == lesson.classroomId &&
        live.location?.signed == true) {
      return Future.value(AttendanceStatus.signed);
    }
    return _logged(AppLogEvent.attendance, () => api.attendance(lesson));
  }

  Future<Presentation> loadPresentation(
    Lesson lesson,
    String presentationId, {
    bool live = false,
  }) => api.presentation(
    lesson.id,
    presentationId,
    session: live ? classrooms[lesson.id]?.session : null,
  );

  Future<LiveClass> enter(Lesson lesson, {bool automatic = false}) {
    final existing = classrooms[lesson.id];
    if (existing != null &&
        account?.id == existing.session.userId &&
        !existing.ended) {
      return Future.value(existing);
    }
    return _entering.putIfAbsent(
      lesson.id,
      () =>
          _logged(
            AppLogEvent.enter,
            () => _enter(lesson, automatic: automatic),
          ).whenComplete(() {
            _entering.remove(lesson.id);
          }),
    );
  }

  Future<LiveClass> _enter(Lesson lesson, {bool automatic = false}) async {
    if (account == null) throw const ApiFailure('请先登录');
    if (!lesson.live) throw const ApiFailure('历史课堂请查看详情');
    final generation = _generation;
    if (automatic && !_automaticAllowed) throw const ApiFailure('后台服务已关闭');
    final session = await api.checkin(lesson.id);
    logs.protectSecrets([session.bearer, session.lessonToken]);
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
            logs.add(
              AppLogEvent.connection,
              detail: status,
              context: {'phase': 'connectionState', 'lessonId': lesson.id},
            );
            _notify();
          }
        },
        onEvent: (event) {
          if (!_valid(live)) return;
          final eventEpoch = _automationEpoch;
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
            for (final timer in live._questionTimingTimers.values) {
              timer.cancel();
            }
            live._questionTimingTimers.clear();
            live.activeProblemIds.clear();
            live.connectionLabel = '课堂已结束';
            _invalidateLocation(live, keepSigned: true);
            unawaited(live.connection?.close() ?? Future.value());
            unawaited(syncAnswers(live));
            unawaited(_updateBackground());
            _notify();
          }
          if (event['op'] == 'locationcheckinext' ||
              event['op'] == 'locationcheckinend') {
            _invalidateLocation(
              live,
              keepSigned: event['op'] == 'locationcheckinend',
            );
            event['_roundInvalidated'] = true;
          }
          live.eventQueue = live.eventQueue
              .then(
                (_) => eventEpoch == _automationEpoch
                    ? processEvent(live, event, epoch: eventEpoch)
                    : Future<void>.value(),
              )
              .catchError((Object failure) {
                logs.add(
                  AppLogEvent.classroomEvent,
                  success: false,
                  error: failure,
                  context: {'phase': str(event['op']), 'lessonId': lesson.id},
                );
                if (_valid(live) && eventEpoch == _automationEpoch) {
                  live.error = failure.toString();
                  _notify();
                }
              });
        },
      );
      if (_automaticAllowed) unawaited(live.connection!.connect());
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
  Future<void> processEvent(LiveClass live, Json event, {int? epoch}) async {
    final eventEpoch = epoch ?? _automationEpoch;
    bool current() => _valid(live) && eventEpoch == _automationEpoch;
    if (!current() || live.ended) return;
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
      for (final timer in live._questionTimingTimers.values) {
        timer.cancel();
      }
      live._questionTimingTimers.clear();
      live.activeProblemIds.clear();
      live.connectionLabel = '课堂已结束';
      _invalidateLocation(live, keepSigned: true);
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
      if (op == 'hello' || id.isEmpty) {
        for (final entry in timeline.reversed) {
          if (entry['type'] == 'slide' && str(entry['pres']).isNotEmpty) {
            id = str(entry['pres']);
            teacherIndex = integer(entry['si'], 1) - 1;
            break;
          }
        }
      }
      if (id.isNotEmpty) {
        await _showPresentation(live, id, epoch: eventEpoch);
        if (!current()) return;
        live.teacherSlideIndex = teacherIndex;
        if (live.followTeacher) {
          selectSlide(live, teacherIndex, fromTeacher: true);
        }
      }
      for (final entry in timeline) {
        if (entry['type'] == 'problem') {
          await _unlock(
            live,
            entry,
            sequence: sequence,
            fromTimeline: true,
            epoch: eventEpoch,
          );
          if (!current()) return;
        }
      }
      if (op == 'hello') live.awaitingTimeline = false;
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
      await _unlock(
        live,
        object(event['problem']),
        sequence: sequence,
        epoch: eventEpoch,
      );
      if (!current()) return;
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
          await _unlock(
            live,
            entry,
            sequence: sequence,
            fromTimeline: true,
            epoch: eventEpoch,
          );
          if (!current()) return;
        }
      }
      live.awaitingTimeline = false;
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
            live._questionVersions.update(
              questionId,
              (value) => value + 1,
              ifAbsent: () => 1,
            );
            live._preparedAutomaticAnswers.remove(questionId);
            live._answerableSince.remove(questionId);
            live._timingConfirmed.remove(questionId);
            live._questionTimingTimers.remove(questionId)?.cancel();
            live.questions.remove(questionId);
          }
        }
        await _showPresentation(live, id, activate: current, epoch: eventEpoch);
        if (!_valid(live) || eventEpoch != _automationEpoch) return;
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
        _invalidateLocation(live, keepSigned: op == 'locationcheckinend');
      }
      if (op == 'locationcheckinext') {
        try {
          await locationStatus(live);
          unawaited(_runAutomaticLocationCheckin(live));
        } catch (_) {
          live.error = '位置签到状态获取失败，请手动刷新';
        }
      }
      unawaited(syncAttendance(live));
    }
    if (!current()) return;
    _notify();
    unawaited(_runAutomatic(live));
  }

  Future<void> _showPresentation(
    LiveClass live,
    String id, {
    bool activate = true,
    int? epoch,
  }) async {
    final eventEpoch = epoch ?? _automationEpoch;
    if (!_valid(live)) return;
    if (!live.presentations.containsKey(id)) {
      final watch = Stopwatch()..start();
      final presentation = await api.presentation(
        live.lesson.id,
        id,
        session: live.session,
        withAnswers: false,
      );
      if (!_valid(live) || eventEpoch != _automationEpoch) return;
      logs.add(
        AppLogEvent.classroomEvent,
        success: true,
        detail: '已加载课件，开始检查自动作答',
        elapsed: watch.elapsed,
        context: {
          'phase': 'presentationLoaded',
          'lessonId': live.lesson.id,
          'presentationId': id,
          'slideCount': presentation.slides.length,
          'questionCount': presentation.slides
              .where((slide) => slide.question != null)
              .length,
          'enabled': settings.autoAnswer,
          'requested': _automaticAllowed,
          'reason': !settings.autoAnswer
              ? 'automationDisabled'
              : !_automaticAllowed
              ? 'executionSuspended'
              : 'ready',
        },
      );
      live.presentations[id] = presentation;
      for (final slide in presentation.slides) {
        if (slide.question != null) {
          var question = slide.question!;
          final previous = live.questions[question.id];
          if (previous != null &&
              _questionContent(previous) == _questionContent(question)) {
            // A refresh must not replace authoritative timing with the raw PPT
            // copy, or detach its existing timer and pre-generated answer.
            live.questions[question.id] = previous;
            continue;
          }
          if (previous != null) {
            live._questionVersions.update(
              question.id,
              (value) => value + 1,
              ifAbsent: () => 1,
            );
            live._preparedAutomaticAnswers.remove(question.id);
            live._failedAutomaticQuestionIds.remove(question.id);
            live._editedDrafts.remove(question.id);
            live.draftAnswers.remove(question.id);
            _cancelAutomaticSubmission(live, question.id);
          }
          final launch = live.launches[question.id];
          if (previous != null) {
            question = question.launched(
              previous.dt,
              previous.limit,
              serverOffsetMillis: previous.serverOffsetMillis,
            );
          } else if (launch != null) {
            question = question.launched(
              integer(launch['dt']),
              integer(launch['limit']),
            );
          }
          live.questions[question.id] = question;
          _armQuestionTiming(live, question);
        }
      }
    }
    if (activate && live.presentationId != id) {
      live.presentationId = id;
      live.slideIndex = 0;
      live.answersKnown = false;
    }
    // Preparation is independent of the teacher's publish event and of the
    // personal-answer lookup; only submitting requires those confirmations.
    unawaited(_runAutomatic(live));
  }

  String _questionContent(Question question) => jsonEncode({
    'body': question.body,
    'type': question.type,
    'options': question.options,
    'blankCount': question.blankCount,
    'selectionLimit': question.selectionLimit,
  });

  Future<void> _unlock(
    LiveClass live,
    Json data, {
    required int sequence,
    bool fromTimeline = false,
    int? epoch,
  }) async {
    final eventEpoch = epoch ?? _automationEpoch;
    final id = str(data['prob']);
    if (id.isEmpty) return;
    final closed = live.closedAtSequence[id];
    if (closed != null && (fromTimeline || sequence <= closed)) return;
    final previous = live.launches[id];
    if (previous != null && integer(previous['dt']) > integer(data['dt'])) {
      return;
    }
    var question = live.questions[id];
    final presentationId = str(data['pres']);
    if (question == null && presentationId.isNotEmpty) {
      await _showPresentation(
        live,
        presentationId,
        activate: false,
        epoch: eventEpoch,
      );
      question = live.questions[id];
    }
    if (!_valid(live) || eventEpoch != _automationEpoch) return;
    live.launches[id] = data;
    if (question == null) {
      live.error = '收到题目通知，但题干尚未加载，请刷新课堂';
      return;
    }
    if (live.closedAtSequence[id] != null &&
        sequence <= live.closedAtSequence[id]!) {
      return;
    }
    if (!fromTimeline) live.closedAtSequence.remove(id);
    if (question.dt > 0 && question.dt != integer(data['dt'])) {
      _cancelAutomaticSubmission(live, id);
      live._questionVersions.update(
        id,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      live._preparedAutomaticAnswers.remove(id);
      live._failedAutomaticQuestionIds.remove(id);
      live._answerableSince.remove(id);
      live._timingConfirmed.remove(id);
      live._editedDrafts.remove(id);
      live.draftAnswers.remove(id);
    }
    question = question.launched(
      integer(data['dt']),
      integer(data['limit']),
      serverOffsetMillis: data['now'] == null
          ? null
          : integer(data['now']) - now().millisecondsSinceEpoch,
    );
    live.questions[id] = question;
    if (fromTimeline && connectSockets) {
      live._timingConfirmed.remove(id);
      live.activeProblemIds.remove(id);
      live.autoStates[id] = answerStatus(live, question);
      if (live.connection?.requestProblemInfo(id) != true) {
        live.error = '答题时间尚未确认，请刷新课堂连接';
      }
    } else if (_inWindow(question)) {
      live._timingConfirmed.add(id);
      live.activeProblemIds.add(id);
      live._answerableSince[id] = _publishedAt(question);
    } else {
      if (data['limit'] is num) live._timingConfirmed.add(id);
      live.activeProblemIds.remove(id);
      live.autoStates[id] = answerStatus(live, question);
    }
    if (data['limit'] is! num || question.dt <= 0) {
      live._timingConfirmed.remove(id);
      live.activeProblemIds.remove(id);
      live.autoStates[id] = '正在确认作答时间';
      live.connection?.requestProblemInfo(id);
    }
    _armQuestionTiming(live, question);
  }

  void _closeProblem(LiveClass live, String id, int sequence) {
    if (id.isEmpty) return;
    _cancelAutomaticSubmission(live, id);
    live.closedAtSequence[id] = sequence;
    live.activeProblemIds.remove(id);
    live._answerableSince.remove(id);
    live._questionTimingTimers.remove(id)?.cancel();
    live.autoStates[id] = live.answers.containsKey(id) ? '答案已提交' : '作答已结束';
    _driveAutomaticQueue(live);
    _notify();
  }

  void _applyTiming(LiveClass live, Question question, Json timing) {
    if (timing['limit'] is! num || (timing['dt'] == null && question.dt <= 0)) {
      _cancelAutomaticSubmission(live, question.id, message: '答题时间未确认，已取消自动提交');
      live.activeProblemIds.remove(question.id);
      live._timingConfirmed.remove(question.id);
      live._questionTimingTimers.remove(question.id)?.cancel();
      live.error = '题目时限未能确认，请刷新课堂';
      return;
    }
    final updated = question.launched(
      integer(timing['dt'], question.dt),
      integer(timing['limit']),
      serverOffsetMillis: timing['now'] == null
          ? null
          : integer(timing['now']) - now().millisecondsSinceEpoch,
    );
    if (question.dt > 0 && updated.dt != question.dt) {
      _cancelAutomaticSubmission(live, question.id, message: '题目已变化，已取消自动提交');
      live._questionVersions.update(
        question.id,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      live._preparedAutomaticAnswers.remove(question.id);
      live._failedAutomaticQuestionIds.remove(question.id);
      live._answerableSince.remove(question.id);
      live._editedDrafts.remove(question.id);
      live.draftAnswers.remove(question.id);
    }
    live.questions[question.id] = updated;
    live._timingConfirmed.add(question.id);
    if (_inWindow(updated)) {
      live.activeProblemIds.add(question.id);
      live._answerableSince[question.id] = _publishedAt(updated);
    } else {
      live.activeProblemIds.remove(question.id);
      live._answerableSince.remove(question.id);
      _cancelAutomaticSubmission(live, question.id);
      live.autoStates[question.id] = answerStatus(live, updated);
    }
    _armQuestionTiming(live, updated);
  }

  void _armQuestionTiming(LiveClass live, Question question) {
    final id = question.id;
    live._questionTimingTimers.remove(id)?.cancel();
    if (!_valid(live) ||
        live.ended ||
        live.closedAtSequence.containsKey(id) ||
        !live._timingConfirmed.contains(id)) {
      return;
    }
    final serverNow = _questionTime(question);
    final target = serverNow < question.dt
        ? question.dt
        : question.limit > 0
        ? question.dt + question.limit * 1000
        : null;
    if (target == null || target <= serverNow) return;
    live._questionTimingTimers[id] = Timer(
      Duration(milliseconds: target - serverNow),
      () {
        live._questionTimingTimers.remove(id);
        if (!_valid(live) ||
            live.ended ||
            !_automaticAllowed ||
            live.closedAtSequence.containsKey(id) ||
            live.questions[id] != question) {
          return;
        }
        if (_questionEnded(live, question)) {
          live.activeProblemIds.remove(id);
          _cancelAutomaticSubmission(live, id);
          live.autoStates[id] = answerStatus(live, question);
        } else if (_inWindow(question)) {
          live.activeProblemIds.add(id);
          live._answerableSince[id] = _publishedAt(question);
          _armQuestionTiming(live, question);
          unawaited(_runAutomatic(live));
        }
        _driveAutomaticQueue(live);
        _notify();
      },
    );
  }

  int _questionTime(Question question) =>
      now().millisecondsSinceEpoch + question.serverOffsetMillis;

  DateTime _publishedAt(Question question) =>
      DateTime.fromMillisecondsSinceEpoch(
        question.dt - question.serverOffsetMillis,
      );

  bool _inWindow(Question question) =>
      question.dt > 0 &&
      _questionTime(question) >= question.dt &&
      (question.limit == -1 ||
          question.limit > 0 &&
              _questionTime(question) < question.dt + question.limit * 1000);

  bool _questionEnded(LiveClass live, Question question) =>
      live.ended ||
      live.closedAtSequence.containsKey(question.id) ||
      question.dt > 0 &&
          (question.limit == 0 && live._timingConfirmed.contains(question.id) ||
              question.limit > 0 &&
                  _questionTime(question) >=
                      question.dt + question.limit * 1000);

  bool canSubmitAnswer(LiveClass live, Question question) {
    final current = live.questions[question.id] ?? question;
    return _valid(live) &&
        !live.answers.containsKey(question.id) &&
        !live.submitting.contains(question.id) &&
        !live.ended &&
        !live.closedAtSequence.containsKey(question.id) &&
        live.activeProblemIds.contains(question.id) &&
        _inWindow(current);
  }

  bool canEditAnswer(LiveClass live, Question question) =>
      _valid(live) &&
      !live.answers.containsKey(question.id) &&
      !live.submitting.contains(question.id) &&
      !_questionEnded(live, live.questions[question.id] ?? question);

  String answerStatus(LiveClass live, Question question) {
    final current = live.questions[question.id] ?? question;
    if (live.answers.containsKey(question.id)) return '答案已提交';
    if (_questionEnded(live, current)) return '作答已结束';
    if (live.submitting.contains(question.id)) return '正在提交答案';
    if (current.dt <= 0 || _questionTime(current) < current.dt) {
      if (live.draftAnswers.containsKey(question.id)) return '答案已填充，等待开始作答';
      return live.autoStates[question.id] == 'AI 正在作答' ? 'AI 正在作答' : '尚未开始作答';
    }
    if (!live.activeProblemIds.contains(question.id)) return '正在确认作答时间';
    final status = live.autoStates[question.id];
    if (status != null &&
        !const {
          '正在确认作答时间',
          '正在确认答题时间',
          '尚未开始作答',
          '答案已填充，等待开始作答',
          '答案已提交',
          '作答已结束',
        }.contains(status)) {
      return status;
    }
    return live.draftAnswers.containsKey(question.id) ? '答案已填充，待确认提交' : '可以作答';
  }

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
    final watch = Stopwatch()..start();
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
          final answers = await api.ownAnswers(
            live.lesson.id,
            id,
            session: live.session,
          );
          if (!_valid(live)) return;
          live.answers.addAll(answers);
        } catch (failure) {
          known = false;
          failures.add(failure.toString());
          logs.add(
            AppLogEvent.answers,
            success: false,
            error: failure,
            context: {
              'phase': 'livePresentationResults',
              'lessonId': live.lesson.id,
              'presentationId': id,
            },
          );
        }
      }
    }
    if (!_valid(live)) return;
    live.answersKnown = known;
    if (known) live._automaticSubmissionUncertain = false;
    live.syncingAnswers = false;
    live.answerSyncError = failures.isEmpty ? null : failures.join('\n');
    if (known) {
      logs.add(
        AppLogEvent.answers,
        success: true,
        elapsed: watch.elapsed,
        count: live.answers.length,
        context: {
          'phase': 'syncedLiveResults',
          'lessonId': live.lesson.id,
          'presentationCount': queried.length,
        },
      );
    }
    live.draftAnswers.removeWhere((id, _) => live.answers.containsKey(id));
    for (final id in live.answers.keys) {
      _cancelAutomaticSubmission(live, id);
      live._questionTimingTimers.remove(id)?.cancel();
      live.autoStates[id] = '答案已提交';
    }
    _observeSubmittedAnswers(live, live.answers.values);
    try {
      await _persistAnswers(live);
    } catch (failure) {
      live.error = '答案已读取，但未能保存到本机';
      logs.add(
        AppLogEvent.answers,
        success: false,
        error: failure,
        context: {'phase': 'persistSyncedResults', 'lessonId': live.lesson.id},
      );
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
    if (!canSubmitAnswer(live, latest)) {
      throw ApiFailure(answerStatus(live, latest));
    }
    live.submitting.add(question.id);
    final watch = Stopwatch()..start();
    _notify();
    try {
      await api.submit(live.session, latest, answer);
      logs.add(
        AppLogEvent.submit,
        success: true,
        elapsed: watch.elapsed,
        context: {
          'phase': 'posted',
          'lessonId': live.lesson.id,
          'problemId': question.id,
          'questionType': question.type,
        },
      );
      if (!_valid(live)) return;
      live.answers[question.id] = AnswerRecord(
        problemId: question.id,
        answer: answer,
        source: AnswerSource.local,
        submittedAt: now().millisecondsSinceEpoch,
      );
      _observeSubmittedAnswers(live, [live.answers[question.id]!], at: now());
      live.draftAnswers.remove(question.id);
      live._questionTimingTimers.remove(question.id)?.cancel();
      live.autoStates[question.id] = '答案已提交';
      try {
        await _persistAnswers(live);
      } catch (failure) {
        live.error = '提交已成功，但本机保存失败，请同步远端答案';
        logs.add(
          AppLogEvent.submit,
          success: false,
          error: failure,
          context: {
            'phase': 'persistSubmittedResult',
            'lessonId': live.lesson.id,
            'problemId': question.id,
          },
        );
      }
    } catch (failure) {
      // A timed-out POST might have reached the server. Never retry it blindly.
      logs.add(
        AppLogEvent.submit,
        success: false,
        error: failure,
        elapsed: watch.elapsed,
        detail: '提交结果未确认，不会自动重复提交',
        context: {
          'phase': 'postUncertain',
          'lessonId': live.lesson.id,
          'problemId': question.id,
          'questionType': question.type,
        },
      );
      live.answersKnown = false;
      live._automaticSubmissionUncertain = true;
      live._automaticPostAttemptedRounds.add('${question.id}:${latest.dt}');
      live._failedAutomaticQuestionIds.add(question.id);
      live.answerSyncError = '提交结果未确认，请先同步我的答案再决定是否重试';
      rethrow;
    } finally {
      live.submitting.remove(question.id);
      _driveAutomaticQueue(live);
      _notify();
    }
  }

  void _cancelAutomaticSubmission(
    LiveClass live,
    String id, {
    String? message,
  }) {
    final pending = live._automaticSubmissions.remove(id);
    if (pending != null && message != null) live.autoStates[id] = message;
  }

  void _cancelAutomaticSubmissions(LiveClass live, {String? message}) {
    live._automaticQueueTimer?.cancel();
    live._automaticQueueTimer = null;
    for (final id in List.of(live._automaticSubmissions.keys)) {
      _cancelAutomaticSubmission(live, id, message: message);
    }
  }

  void _observeSubmittedAnswers(
    LiveClass live,
    Iterable<AnswerRecord> answers, {
    DateTime? at,
  }) {
    var changed = false;
    for (final answer in answers) {
      if (live._observedSubmittedIds.add(answer.problemId)) changed = true;
    }
    if (changed) {
      // Remote summaries do not expose submission timestamps. First detection
      // is a conservative local spacing anchor, never a fabricated server time.
      live._lastSuccessfulSubmission = at ?? now();
    }
  }

  /// A user's edit invalidates both a queued submission and an earlier AI result.
  /// Keep the editable answer so rebuilding a card cannot restore the old result.
  void updateAnswerDraft(LiveClass live, Question question, dynamic answer) {
    if (!canEditAnswer(live, question)) return;
    live._editedDrafts.add(question.id);
    live.draftAnswers[question.id] = answer;
    _cancelAutomaticSubmission(live, question.id);
    live._automaticSubmissionAttempts.removeWhere(
      (attempt) => attempt.startsWith('${question.id}:'),
    );
    live.autoStates[question.id] = '答案已修改，待确认提交';
    live._failedAutomaticQuestionIds.remove(question.id);
    _maybeSubmitPreparedDraft(live, live.questions[question.id] ?? question);
    _driveAutomaticQueue(live);
    _notify();
  }

  bool _automaticSubmissionValid(LiveClass live, _AutomaticSubmission job) {
    final id = job.question.id;
    return _valid(live) &&
        _automaticAllowed &&
        identical(live._automaticSubmissions[id], job) &&
        job.generation == _generation &&
        settings.autoAnswer &&
        settings.autoSubmit &&
        job.settingsSnapshot == jsonEncode(settings.toJson()) &&
        !live.ended &&
        !live._automaticSubmissionUncertain &&
        live.answersKnown &&
        !live.syncingAnswers &&
        !live.awaitingTimeline &&
        !live.answers.containsKey(id) &&
        !live.submitting.contains(id) &&
        _automaticDraftError(live.questions[id] ?? job.question, job.answer) ==
            null &&
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
    if (live._automaticPostAttemptedRounds.contains('$id:${current.dt}')) {
      return;
    }
    if (live._automaticSubmissions.containsKey(id)) return;
    final attempt = '$id:${current.dt}:$settingsSnapshot';
    if (!live._automaticSubmissionAttempts.add(attempt)) return;
    final job = _AutomaticSubmission(
      generation: generation,
      settingsSnapshot: settingsSnapshot,
      question: question,
      answer: answer,
    );
    live._automaticSubmissions[id] = job;
    _driveAutomaticQueue(live);
  }

  List<Question> _automaticQuestionOrder(LiveClass live) {
    final pageOrder = <String, int>{};
    var order = 0;
    for (final deck in live.presentations.values) {
      for (final slide in deck.slides) {
        if (slide.question != null) {
          pageOrder.putIfAbsent(slide.question!.id, () => order);
        }
        order++;
      }
    }
    final questions = live.questions.values
        .where(
          (question) =>
              live._answerableSince.containsKey(question.id) &&
              !live.answers.containsKey(question.id) &&
              !_questionEnded(live, question) &&
              !live._failedAutomaticQuestionIds.contains(question.id) &&
              !live._automaticPostAttemptedRounds.contains(
                '${question.id}:${question.dt}',
              ),
        )
        .toList();
    questions.sort((a, b) {
      final published = a.dt.compareTo(b.dt);
      if (published != 0) return published;
      final page = (pageOrder[a.id] ?? 1 << 30).compareTo(
        pageOrder[b.id] ?? 1 << 30,
      );
      return page != 0 ? page : a.id.compareTo(b.id);
    });
    return questions;
  }

  DateTime _automaticDue(LiveClass live, Question question) {
    final delay = Duration(seconds: settings.autoSubmitDelaySeconds);
    var due = (live._answerableSince[question.id] ?? now()).add(delay);
    final spaced = live._lastSuccessfulSubmission?.add(delay);
    if (spaced != null && spaced.isAfter(due)) due = spaced;
    return due;
  }

  void _driveAutomaticQueue(LiveClass live) {
    live._automaticQueueTimer?.cancel();
    live._automaticQueueTimer = null;
    if (!_valid(live) ||
        !_automaticAllowed ||
        live.ended ||
        !settings.autoAnswer ||
        !settings.autoSubmit ||
        live._automaticQueueRunning) {
      return;
    }
    final ordered = _automaticQuestionOrder(live);
    if (ordered.isEmpty) return;
    final head = ordered.first;
    final job = live._automaticSubmissions[head.id];
    if (live.draftAnswers.containsKey(head.id)) {
      final error = _automaticDraftError(head, live.draftAnswers[head.id]);
      if (error != null) {
        live.autoStates[head.id] = error;
        return;
      }
    }
    for (final question in ordered.skip(1)) {
      if (live.draftAnswers.containsKey(question.id)) {
        live.autoStates[question.id] = '答案已填充，等待前题提交';
      }
    }
    if (live._automaticSubmissionUncertain ||
        !live.answersKnown ||
        live.syncingAnswers ||
        live.awaitingTimeline) {
      if (live.draftAnswers.containsKey(head.id)) {
        live.autoStates[head.id] = '自动提交等待同步，仍可手动提交';
      }
      return;
    }
    if (live.submitting.isNotEmpty || job == null) return;
    if (!_automaticSubmissionValid(live, job)) return;
    final due = _automaticDue(live, head);
    if (head.limit > 0 &&
        due.millisecondsSinceEpoch + head.serverOffsetMillis >=
            head.dt + head.limit * 1000) {
      live.autoStates[head.id] = '答题剩余时间不足，已取消自动提交';
      live._automaticSubmissions.remove(head.id);
      live._failedAutomaticQuestionIds.add(head.id);
      _driveAutomaticQueue(live);
      return;
    }
    final remaining = due.difference(now());
    final seconds = remaining.isNegative
        ? 0
        : (remaining.inMilliseconds / 1000).ceil();
    live.autoStates[head.id] = '答案已填充，$seconds 秒后自动提交';
    live._automaticQueueTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        live._automaticQueueTimer = null;
        if (live._automaticQueueRunning) return;
        live._automaticQueueRunning = true;
        unawaited(_submitAutomatic(live, job));
      },
    );
  }

  Future<void> _submitAutomatic(
    LiveClass live,
    _AutomaticSubmission job,
  ) async {
    final id = job.question.id;
    var posting = false;
    var retain = false;
    try {
      if (!_automaticSubmissionValid(live, job)) {
        if (identical(live._automaticSubmissions[id], job)) {
          live.autoStates[id] =
              live.answers.containsKey(id) ||
                  _questionEnded(live, live.questions[id] ?? job.question)
              ? answerStatus(live, job.question)
              : '课堂或设置已变化，已取消自动提交';
        }
        return;
      }
      // Waiting gives other clients time to submit; query again just before POST.
      final deck = live.presentations.values
          .where((deck) => deck.slides.any((slide) => slide.question?.id == id))
          .firstOrNull;
      if (deck != null) {
        final remote = await api.ownAnswers(
          live.lesson.id,
          deck.id,
          session: live.session,
        );
        if (!_automaticSubmissionValid(live, job)) return;
        live.answers.addAll(remote);
        _observeSubmittedAnswers(live, remote.values);
        if (live.answers.containsKey(id)) {
          live.draftAnswers.remove(id);
          live._questionTimingTimers.remove(id)?.cancel();
          live.autoStates[id] = '答案已提交';
          await _persistAnswers(live);
          return;
        }
      }
      final latest = live.questions[id] ?? job.question;
      if (live.submitting.isNotEmpty ||
          _automaticDue(live, latest).isAfter(now())) {
        retain = true;
        return;
      }
      if (!_automaticSubmissionValid(live, job)) {
        if (identical(live._automaticSubmissions[id], job)) {
          live.autoStates[id] =
              live.answers.containsKey(id) ||
                  _questionEnded(live, live.questions[id] ?? job.question)
              ? answerStatus(live, job.question)
              : '课堂或设置已变化，已取消自动提交';
        }
        return;
      }
      posting = true;
      live._automaticPostAttemptedRounds.add('$id:${job.question.dt}');
      live.autoStates[id] = '正在自动提交';
      await submitAnswer(live, job.question, job.answer);
      if (_valid(live)) live.autoStates[id] = '答案已提交';
    } catch (failure) {
      logs.add(
        AppLogEvent.automatic,
        success: false,
        error: failure,
        context: {
          'phase': posting ? 'automaticPost' : 'automaticPreflight',
          'lessonId': live.lesson.id,
          'problemId': id,
        },
      );
      if (_valid(live) &&
          (identical(live._automaticSubmissions[id], job) ||
              posting &&
                  jsonEncode(live.draftAnswers[id]) == jsonEncode(job.answer) &&
                  job.settingsSnapshot == jsonEncode(settings.toJson()) &&
                  live.questions[id]?.dt == job.question.dt)) {
        live._failedAutomaticQuestionIds.add(id);
        live.autoStates[id] = '自动答题未完成：$failure';
      }
    } finally {
      if (!retain && identical(live._automaticSubmissions[id], job)) {
        live._automaticSubmissions.remove(id);
      }
      live._automaticQueueRunning = false;
      _driveAutomaticQueue(live);
      if (_valid(live)) _notify();
    }
  }

  void _maybeSubmitPreparedDraft(LiveClass live, Question question) {
    final id = question.id;
    if (!_valid(live) || live.answers.containsKey(id)) {
      if (live.answers.containsKey(id)) live.autoStates[id] = '答案已提交';
      return;
    }
    if (!_automaticAllowed || !settings.autoAnswer) return;
    if (_questionEnded(live, question)) {
      _cancelAutomaticSubmission(live, id);
      live.autoStates[id] = '作答已结束';
      return;
    }
    if (!live.draftAnswers.containsKey(id)) return;
    if (!live.activeProblemIds.contains(id) || !_inWindow(question)) {
      live.autoStates[id] = question.dt > 0 ? '正在确认作答时间' : '答案已填充，等待开始作答';
      return;
    }
    if (!settings.autoSubmit) {
      live.autoStates[id] = live._editedDrafts.contains(id)
          ? '答案已修改，待确认提交'
          : '答案已填充，待确认提交';
      return;
    }
    final draftError = _automaticDraftError(question, live.draftAnswers[id]);
    if (draftError != null) {
      _cancelAutomaticSubmission(live, id);
      live.autoStates[id] = draftError;
      return;
    }
    if (!live.answersKnown || live.syncingAnswers || live.awaitingTimeline) {
      live.autoStates[id] = '自动提交等待同步，仍可手动提交';
      return;
    }
    _scheduleAutomaticSubmission(
      live,
      question,
      live.draftAnswers[id],
      _generation,
      jsonEncode(settings.toJson()),
      settings.autoSubmitDelaySeconds,
    );
  }

  String? _automaticDraftError(Question question, dynamic answer) {
    if (question.isJudgment || [1, 2, 3, 6].contains(question.type)) {
      if (answer is! List || answer.isEmpty) return '请选择答案，等待补全后自动提交';
      if (answer.any(
            (value) => value is! String || !question.options.containsKey(value),
          ) ||
          answer.toSet().length != answer.length) {
        return '答案选项无效，等待修改后自动提交';
      }
      if ((question.isJudgment || question.type == 1) && answer.length != 1) {
        return '只能选择一个选项，等待修改后自动提交';
      }
      if (question.type == 3 && answer.length > question.selectionLimit) {
        return '最多选择 ${question.selectionLimit} 项，等待修改后自动提交';
      }
      return null;
    }
    if (question.type == 4) {
      if (answer is! List ||
          answer.length != question.blankCount ||
          answer.any((value) => value is! String || value.trim().isEmpty)) {
        return '请填写全部 ${question.blankCount} 个空，等待补全后自动提交';
      }
      return null;
    }
    if (question.type == 5) {
      if (answer is! Map ||
          str(answer['content']).trim().isEmpty &&
              array(answer['pics']).isEmpty) {
        return '请填写答案或添加图片，等待补全后自动提交';
      }
      return null;
    }
    return '暂不支持此题型自动提交';
  }

  Future<void> _runAutomatic(LiveClass live) async {
    if (!_valid(live) ||
        !_automaticAllowed ||
        live.ended ||
        !settings.autoAnswer) {
      return;
    }
    final settingsSnapshot = _automaticAnswerSettings(settings);
    for (final question in List.of(live.questions.values)) {
      final id = question.id;
      if (live.answers.containsKey(id) || _questionEnded(live, question)) {
        _logAutomaticSkip(
          live,
          question,
          live.answers.containsKey(id) ? 'alreadySubmitted' : 'questionEnded',
        );
        live.autoStates[id] = answerStatus(live, question);
        continue;
      }
      if (live._editedDrafts.contains(id)) {
        _logAutomaticSkip(live, question, 'manualDraft');
        _maybeSubmitPreparedDraft(live, question);
        continue;
      }
      final version = live._questionVersions[id] ?? 0;
      final prepared = live._preparedAutomaticAnswers[id];
      if (prepared != null &&
          prepared.generation == _generation &&
          prepared.questionVersion == version &&
          prepared.settingsSnapshot == settingsSnapshot) {
        live.draftAnswers.putIfAbsent(id, () => prepared.answer);
        _maybeSubmitPreparedDraft(live, question);
        continue;
      }
      // Timing changes at first launch do not change the content being solved.
      // Start each loaded question independently of other provider responses.
      final attempt = '$id:$version:$settingsSnapshot';
      if (!live.automaticAttempts.add(attempt)) continue;
      live._automaticSkipReasons.remove(id);
      final flight = Object();
      live._automaticAnswerFlights[id] = flight;
      unawaited(
        _prepareAutomaticAnswer(
          live,
          question,
          version,
          settingsSnapshot,
          _generation,
          _automationEpoch,
          flight,
        ),
      );
    }
    _driveAutomaticQueue(live);
    _notify();
  }

  Future<void> _prepareAutomaticAnswer(
    LiveClass live,
    Question question,
    int version,
    String settingsSnapshot,
    int generation,
    int automationEpoch,
    Object flight,
  ) async {
    final id = question.id;
    final elapsed = Stopwatch()..start();
    String? invalidReason() {
      if (!_valid(live) || generation != _generation) return 'sessionChanged';
      if (!_automaticAllowed || automationEpoch != _automationEpoch) {
        return 'executionSuspended';
      }
      if (!settings.autoAnswer) return 'automationDisabled';
      if (settingsSnapshot != _automaticAnswerSettings(settings)) {
        return 'answerSettingsChanged';
      }
      if (!identical(live._automaticAnswerFlights[id], flight)) {
        return 'requestSuperseded';
      }
      if (live.ended) return 'lessonEnded';
      if ((live._questionVersions[id] ?? 0) != version ||
          !live.questions.containsKey(id)) {
        return 'questionChanged';
      }
      return null;
    }

    bool current() => invalidReason() == null;
    final context = <String, Object?>{
      'lessonId': live.lesson.id,
      'problemId': id,
      'presentationId': live.presentations.entries
          .where(
            (entry) =>
                entry.value.slides.any((slide) => slide.question?.id == id),
          )
          .firstOrNull
          ?.key,
      'questionType': question.type,
      'attempt': version,
      'generation': generation,
      'source': settings.answerMode.name,
    };
    live.autoStates[id] = settings.answerMode == AnswerMode.ai
        ? 'AI 正在作答'
        : '正在自动作答';
    _notify();
    try {
      final snapshot = AppSettings.fromJson(settings.toJson());
      final fixed = snapshot.fixedAnswerFor(question);
      if (snapshot.answerMode == AnswerMode.fixed &&
          (fixed == null || fixed.trim().isEmpty)) {
        live.autoStates[id] = fixed == null ? '暂不支持此题型自动答题' : '未设置此题型固定答案，已跳过';
        live._failedAutomaticQuestionIds.add(id);
        return;
      }
      logs.add(
        AppLogEvent.automatic,
        detail: '开始生成答案',
        context: {...context, 'phase': 'generationStart'},
      );
      var result = fixed ?? '';
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
        result = await ai.generate(
          settings: snapshot,
          question: question,
          slides: AiAnswerService.selectedSlides(
            presentation,
            page,
            snapshot.slideScope,
          ),
          loadImage: loadImage,
        );
      }
      final invalid = invalidReason();
      if (invalid != null) {
        logs.add(
          AppLogEvent.automatic,
          detail: '生成结果已失效，未填充',
          context: {
            ...context,
            'phase': 'generationDiscard',
            'reason': invalid,
          },
          elapsed: elapsed.elapsed,
        );
        return;
      }
      final latest = live.questions[id]!;
      if (live.answers.containsKey(id) || _questionEnded(live, latest)) {
        logs.add(
          AppLogEvent.automatic,
          detail: '题目已结束或已提交，未填充',
          context: {
            ...context,
            'phase': 'generationDiscard',
            'reason': live.answers.containsKey(id)
                ? 'alreadySubmitted'
                : 'questionEnded',
          },
          elapsed: elapsed.elapsed,
        );
        live.autoStates[id] = answerStatus(live, latest);
        return;
      }
      if (live._editedDrafts.contains(id)) {
        logs.add(
          AppLogEvent.automatic,
          detail: '保留手动编辑的答案',
          context: {
            ...context,
            'phase': 'generationDiscard',
            'reason': 'manualDraft',
          },
          elapsed: elapsed.elapsed,
        );
        _maybeSubmitPreparedDraft(live, latest);
        return;
      }
      final parsed =
          snapshot.answerMode == AnswerMode.fixed &&
              question.type == 4 &&
              !question.isJudgment
          ? List<String>.filled(question.blankCount, result)
          : AiAnswerService.parse(result, question);
      live._preparedAutomaticAnswers[id] = _PreparedAutomaticAnswer(
        generation: generation,
        questionVersion: version,
        settingsSnapshot: settingsSnapshot,
        answer: parsed,
      );
      live.draftAnswers[id] = parsed;
      live._failedAutomaticQuestionIds.remove(id);
      logs.add(
        AppLogEvent.draft,
        success: true,
        detail: '答案已写入草稿',
        context: {...context, 'phase': 'draftFilled'},
        elapsed: elapsed.elapsed,
      );
      _maybeSubmitPreparedDraft(live, latest);
    } catch (failure) {
      logs.add(
        AppLogEvent.automatic,
        success: false,
        error: failure,
        context: {
          ...context,
          'phase': 'generationFailure',
          if (invalidReason() != null) 'reason': invalidReason(),
        },
        elapsed: elapsed.elapsed,
      );
      if (current() &&
          !live._editedDrafts.contains(id) &&
          !live.answers.containsKey(id) &&
          !_questionEnded(live, live.questions[id]!)) {
        live.autoStates[id] = '自动答题未完成：$failure';
        live._failedAutomaticQuestionIds.add(id);
      }
    } finally {
      if (identical(live._automaticAnswerFlights[id], flight)) {
        live._automaticAnswerFlights.remove(id);
      }
      if (_valid(live)) {
        _driveAutomaticQueue(live);
        _notify();
      }
    }
  }

  void _logAutomaticSkip(LiveClass live, Question question, String reason) {
    if (live._automaticSkipReasons[question.id] == reason) return;
    live._automaticSkipReasons[question.id] = reason;
    logs.add(
      AppLogEvent.automatic,
      detail: '跳过自动生成',
      context: {
        'phase': 'generationSkip',
        'lessonId': live.lesson.id,
        'problemId': question.id,
        'questionType': question.type,
        'reason': reason,
      },
    );
  }

  String _automaticAnswerSettings(AppSettings value) => jsonEncode({
    'answerMode': value.answerMode.name,
    if (value.answerMode == AnswerMode.fixed) ...{
      'single': value.fixedSingleAnswer,
      'multiple': value.fixedMultipleAnswer,
      'judgment': value.fixedJudgmentAnswer,
      'subjective': value.fixedSubjectiveAnswer,
    } else ...{
      'baseUrl': value.baseUrl,
      'apiKey': value.apiKey,
      'model': value.model,
      'prompt': value.customPrompt,
      'slidePrompt': value.slidePrompt,
      'slideScope': value.slideScope.name,
    },
  });

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

  void _invalidateLocation(LiveClass live, {bool keepSigned = false}) {
    api.locationRoundChanged(live.lesson.id);
    live._locationRevision++;
    final previous = live.location;
    if (keepSigned && previous?.signed == true) {
      live.location = LocationCheckin(
        signed: true,
        available: false,
        latitude: previous!.latitude,
        longitude: previous.longitude,
        address: previous.address,
        roundId: previous.roundId,
      );
      return;
    }
    live.location = null;
    if (live._attendanceFromLocation) {
      live.attendance = AttendanceStatus.unknown;
      live._attendanceFromLocation = false;
      live.attendanceError = null;
    }
  }

  void _applyLocationStatus(LiveClass live, LocationCheckin status) {
    live.location = status;
    if (status.signed) {
      live.attendance = AttendanceStatus.signed;
      live._attendanceFromLocation = true;
      live.attendanceError = null;
    } else if (live._attendanceFromLocation) {
      live.attendance = AttendanceStatus.unknown;
      live._attendanceFromLocation = false;
    }
  }

  Future<void> syncAttendance(LiveClass live) async {
    if (!_valid(live) || live.syncingAttendance) return;
    final revision = live._locationRevision;
    live.syncingAttendance = true;
    live.attendanceError = null;
    try {
      if (!live.ended) {
        try {
          await locationStatus(live);
        } catch (failure) {
          // Position eligibility is supplemental evidence. Its failure must
          // not hide a reliable ordinary attendance report.
          logs.add(
            AppLogEvent.location,
            success: false,
            error: failure,
            context: {'phase': 'eligibility', 'lessonId': live.lesson.id},
          );
        }
      }
      final status = await loadAttendance(live.lesson);
      if (!_valid(live) || revision != live._locationRevision) return;
      if (live.location?.signed == true) {
        live.attendance = AttendanceStatus.signed;
        live._attendanceFromLocation = true;
      } else {
        live.attendance = status;
        live._attendanceFromLocation = false;
      }
    } catch (failure) {
      logs.add(
        AppLogEvent.attendance,
        success: false,
        error: failure,
        context: {'phase': 'syncAttendance', 'lessonId': live.lesson.id},
      );
      if (!_valid(live) || revision != live._locationRevision) return;
      if (live.location?.signed == true) {
        live.attendance = AttendanceStatus.signed;
        live._attendanceFromLocation = true;
      } else {
        live.attendance = AttendanceStatus.unknown;
        live.attendanceError = '签到状态暂时无法获取';
      }
    } finally {
      live.syncingAttendance = false;
      if (_valid(live)) _notify();
    }
    if (_valid(live) && revision == live._locationRevision) {
      await _runAutomaticLocationCheckin(live);
    }
  }

  Future<LocationCheckin> locationStatus(LiveClass live) async {
    if (!_valid(live) || live.ended) throw const ApiFailure('课堂已结束或账号已退出');
    final revision = live._locationRevision;
    final status = await api.locationStatus(live.session);
    if (!_valid(live) || live.ended || revision != live._locationRevision) {
      throw const ApiFailure('位置签到轮次已变化，请重新查询');
    }
    _applyLocationStatus(live, status);
    _notify();
    return status;
  }

  Future<void> _runAutomaticLocationCheckin(LiveClass live) async {
    final revision = live._locationRevision;
    final epoch = _automationEpoch;
    bool current() =>
        _valid(live) &&
        !live.ended &&
        revision == live._locationRevision &&
        epoch == _automationEpoch &&
        _automaticAllowed &&
        settings.autoEnter &&
        settings.autoLocationCheckin;
    if (!current() || live.location?.signed == true) return;
    final pending = live._locationCheckinFlight;
    if (pending != null) return pending;
    final operation = () async {
      try {
        final status = await locationStatus(live);
        if (!current() || status.signed || !status.available) return;
        final success = await _logged(
          AppLogEvent.location,
          () => api.locationSubmit(live.session, status, shouldSubmit: current),
        );
        if (success && current()) {
          _applyLocationStatus(
            live,
            LocationCheckin(
              signed: true,
              available: status.available,
              latitude: status.latitude,
              longitude: status.longitude,
              address: status.address,
              roundId: status.roundId,
            ),
          );
          _notify();
        }
      } catch (failure) {
        logs.add(
          AppLogEvent.location,
          success: false,
          error: failure,
          context: {
            'phase': 'automaticLocationCheckin',
            'lessonId': live.lesson.id,
          },
        );
        if (current()) {
          live.attendanceError = '位置签到未完成，请刷新状态';
          _notify();
        }
      }
    }();
    live._locationCheckinFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(live._locationCheckinFlight, operation)) {
        live._locationCheckinFlight = null;
        if (revision != live._locationRevision) {
          unawaited(_runAutomaticLocationCheckin(live));
        }
      }
    }
  }

  Future<bool> confirmLocation(
    LiveClass live,
    LocationCheckin confirmed,
  ) async {
    if (!_valid(live) || live.ended) throw const ApiFailure('课堂已结束或账号已退出');
    final revision = live._locationRevision;
    final success = await _logged(
      AppLogEvent.location,
      () => api.locationSubmit(live.session, confirmed),
    );
    if (success &&
        _valid(live) &&
        !live.ended &&
        revision == live._locationRevision) {
      _applyLocationStatus(
        live,
        LocationCheckin(
          signed: true,
          available: confirmed.available,
          latitude: confirmed.latitude,
          longitude: confirmed.longitude,
          address: confirmed.address,
          roundId: confirmed.roundId,
        ),
      );
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
    // A user-requested refresh may retry failed generation. It must never
    // repeat an uncertain POST or replace a manually edited draft.
    for (final question in live.questions.values) {
      final id = question.id;
      if (!live._failedAutomaticQuestionIds.contains(id) ||
          live.answers.containsKey(id) ||
          live._editedDrafts.contains(id) ||
          live._automaticPostAttemptedRounds.contains('$id:${question.dt}')) {
        continue;
      }
      live._failedAutomaticQuestionIds.remove(id);
      live.automaticAttempts.removeWhere(
        (attempt) => attempt.startsWith('$id:'),
      );
      live._automaticAnswerFlights.remove(id);
    }
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
    _activeAttention.clear();
    unawaited(notifications.cancelAll());
    _poller?.cancel();
    _serviceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    background.setStateListener(null);
    for (final live in classrooms.values) {
      _cancelAutomaticSubmissions(live);
      for (final timer in live._questionTimingTimers.values) {
        timer.cancel();
      }
      unawaited(live.connection?.close() ?? Future.value());
    }
    unawaited(background.setEnabled(false));
    _media.close();
    super.dispose();
  }
}
