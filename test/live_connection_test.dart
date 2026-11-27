import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/data/live_connection.dart';
import 'package:ykt_helper/domain/models.dart';

void main() {
  for (final deployment in RainServer.values) {
    test('${deployment.name} socket uses its session deployment', () async {
      final local = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <WebSocket>[];
      final subscription = local.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        peers.add(socket);
        socket.listen((_) {});
      });
      String? target;
      final connection = LiveConnection(
        ClassroomSession(
          userId: 'u',
          lessonId: 'l',
          bearer: 'http',
          lessonToken: 'ws',
          server: deployment,
        ),
        onEvent: (_) {},
        onStatus: (_) {},
        socketFactory: (url) {
          target = url;
          return WebSocket.connect('ws://127.0.0.1:${local.port}/wsapp/');
        },
      );
      try {
        await connection.connect();
        expect(target, 'wss://${deployment.host}/wsapp/');
      } finally {
        await connection.close();
        for (final peer in peers) {
          await peer.close();
        }
        await subscription.cancel();
        await local.close(force: true);
      }
    });
  }

  test(
    'socket hello uses the target lesson token; refresh creates one new connection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = <Json>[];
      final peers = <WebSocket>[];
      final subscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        peers.add(socket);
        socket.listen((value) {
          final event = object(jsonDecode(value as String));
          received.add(event);
          if (event['op'] == 'hello') {
            socket.add(
              jsonEncode({'op': 'hello', 'presentation': 'p', 'slideindex': 1}),
            );
          }
        });
      });
      final events = <Json>[];
      final connection = LiveConnection(
        const ClassroomSession(
          userId: 'user',
          lessonId: 'lesson',
          bearer: 'http-token',
          lessonToken: 'socket-token',
        ),
        onEvent: events.add,
        onStatus: (_) {},
        socketFactory: (_) =>
            WebSocket.connect('ws://127.0.0.1:${server.port}/wsapp/'),
        heartbeatInterval: const Duration(milliseconds: 15),
      );
      try {
        await connection.connect();
        for (var i = 0; i < 100 && events.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(received.single, {
          'op': 'hello',
          'userid': 'user',
          'role': 'student',
          'auth': 'socket-token',
          'lessonid': 'lesson',
        });
        expect(received.single.values, isNot(contains('http-token')));
        for (
          var i = 0;
          i < 100 && !received.any((event) => event['op'] == 'xintiao');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(received.firstWhere((event) => event['op'] == 'xintiao'), {
          'op': 'xintiao',
          'lessonid': 'lesson',
        });
        expect(connection.requestProblemInfo('q'), true);
        await connection.reconnect();
        for (var i = 0; i < 100 && events.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(received.where((event) => event['op'] == 'hello').length, 2);
        expect(events.length, 2);
        await connection.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(peers.length, 2);
      } finally {
        await connection.close();
        for (final peer in peers) {
          await peer.close();
        }
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
