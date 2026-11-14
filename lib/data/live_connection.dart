import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../domain/models.dart';

/// One socket and reconnect loop per account/lesson pair.
class LiveConnection {
  final ClassroomSession session;
  final void Function(Json event) onEvent;
  final void Function(String status) onStatus;
  WebSocket? _socket;
  Timer? _retry;
  Timer? _heartbeat;
  bool _closed = false, _connecting = false;
  int _attempt = 0, _epoch = 0;
  final Future<WebSocket> Function(String url) socketFactory;
  final Duration heartbeatInterval;
  int _messageId = 0;
  LiveConnection(
    this.session, {
    required this.onEvent,
    required this.onStatus,
    Future<WebSocket> Function(String url)? socketFactory,
    this.heartbeatInterval = const Duration(seconds: 30),
  }) : socketFactory = socketFactory ?? WebSocket.connect;
  Future<void> connect() async {
    if (_closed || _connecting) return;
    _connecting = true;
    final epoch = ++_epoch;
    _retry?.cancel();
    onStatus(_attempt == 0 ? '正在连接课堂' : '正在重新连接课堂');
    try {
      final socket = await socketFactory(
        'wss://www.yuketang.cn/wsapp/',
      ).timeout(const Duration(seconds: 20));
      if (_closed || epoch != _epoch) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 25);
      socket.add(
        jsonEncode({
          'op': 'hello',
          'userid': session.userId,
          'role': 'student',
          'auth': session.lessonToken,
          'lessonid': session.lessonId,
        }),
      );
      socket.listen(
        // The app-level heartbeat is required in addition to WebSocket ping.
        (message) {
          if (_closed || epoch != _epoch) return;
          try {
            final value = jsonDecode(
              message is String ? message : utf8.decode(message as List<int>),
            );
            final event = object(value);
            if (event['op'] == 'hello') {
              _attempt = 0;
              onStatus('实时连接正常');
            }
            onEvent(event);
          } on FormatException {
            onStatus('收到无法解析的课堂消息');
          }
        },
        onError: (Object _) => _scheduleReconnect(epoch),
        onDone: () => _scheduleReconnect(epoch),
        cancelOnError: true,
      );
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(heartbeatInterval, (_) {
        if (!_closed && epoch == _epoch) {
          sendJson({'op': 'xintiao', 'lessonid': session.lessonId});
        }
      });
    } on Exception {
      _scheduleReconnect(epoch);
    } finally {
      if (epoch == _epoch) _connecting = false;
    }
  }

  void _scheduleReconnect(int epoch) {
    if (_closed || epoch != _epoch || _retry?.isActive == true) return;
    final socket = _socket;
    _socket = null;
    _heartbeat?.cancel();
    unawaited(socket?.close() ?? Future.value());
    final seconds = (1 << _attempt.clamp(0, 5)).clamp(1, 30);
    _attempt++;
    onStatus('连接中断，$seconds 秒后重连');
    _retry = Timer(Duration(seconds: seconds), connect);
  }

  Future<void> close() async {
    _closed = true;
    _epoch++;
    _connecting = false;
    _retry?.cancel();
    _heartbeat?.cancel();
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close().timeout(const Duration(seconds: 3));
    } on Exception {
      /* The local session is closed even when the peer is gone. */
    }
  }

  Future<void> reconnect() async {
    await close();
    _closed = false;
    _attempt = 0;
    await connect();
  }

  bool sendJson(Json message) {
    final socket = _socket;
    if (_closed || socket == null || socket.readyState != WebSocket.open) {
      return false;
    }
    try {
      socket.add(jsonEncode(message));
      return true;
    } on Exception {
      _scheduleReconnect(_epoch);
      return false;
    }
  }

  bool requestProblemInfo(String id) => sendJson({
    'op': 'probleminfo',
    'lessonid': session.lessonId,
    'problemid': id,
    'msgid': '${++_messageId}',
  });
  bool requestTimeline() => sendJson({
    'op': 'fetchtimeline',
    'lessonid': session.lessonId,
    'msgid': '${++_messageId}',
  });
}
