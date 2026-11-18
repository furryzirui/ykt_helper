import '../domain/models.dart';

/// Opt-in for temporary iOS test builds. Release builds omit this define.
const iosBackgroundDiagnosticsEnabled = bool.fromEnvironment(
  'YKT_IOS_BACKGROUND_DIAGNOSTICS',
  defaultValue: false,
);

enum BackgroundDiagnosticAppState { active, inactive, background }

/// An observation, not proof that iOS will continue executing the application.
/// Only allowlisted enums, booleans and bounded counters cross into the log.
class IosBackgroundSnapshot {
  final bool enabled;
  final BackgroundServiceMode mode;
  final BackgroundDiagnosticAppState appState;
  final bool? audioPlaying, pipActive;
  final int? audioTimeMs, pipFrameCount;
  const IosBackgroundSnapshot._({
    required this.enabled,
    required this.mode,
    required this.appState,
    this.audioPlaying,
    this.audioTimeMs,
    this.pipActive,
    this.pipFrameCount,
  });

  static int? _counter(Object? value) =>
      value is int && value >= 0 && value <= 9007199254740991 ? value : null;

  static IosBackgroundSnapshot? parse(Object? raw) {
    if (raw is! Map || raw['enabled'] is! bool) return null;
    final mode = BackgroundServiceMode.values
        .where((mode) => mode.name == raw['mode'])
        .firstOrNull;
    final appState = BackgroundDiagnosticAppState.values
        .where((state) => state.name == raw['appState'])
        .firstOrNull;
    if (mode == null || appState == null) return null;
    return IosBackgroundSnapshot._(
      enabled: raw['enabled'] as bool,
      mode: mode,
      appState: appState,
      audioPlaying: raw['audioPlaying'] is bool
          ? raw['audioPlaying'] as bool
          : null,
      audioTimeMs: _counter(raw['audioTimeMs']),
      pipActive: raw['pipActive'] is bool ? raw['pipActive'] as bool : null,
      pipFrameCount: _counter(raw['pipFrameCount']),
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'mode': mode.name,
    'appState': appState.name,
    if (audioPlaying != null) 'audioPlaying': audioPlaying,
    if (audioTimeMs != null) 'audioTimeMs': audioTimeMs,
    if (pipActive != null) 'pipActive': pipActive,
    if (pipFrameCount != null) 'pipFrameCount': pipFrameCount,
  };
}
