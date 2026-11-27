import 'package:flutter/services.dart';

/// Local classroom reminders. Permission requests and per-question deduplication
/// belong to the UI/controller; an unavailable platform simply skips delivery.
class ClassroomNotifications {
  static const channelName = 'ykt_helper/classroom_notifications';
  final MethodChannel channel;

  const ClassroomNotifications({
    this.channel = const MethodChannel(channelName),
  });

  Future<bool> show({
    required String key,
    required String title,
    required String body,
    required String lessonId,
    required String problemId,
  }) async {
    if (key.isEmpty || title.isEmpty || lessonId.isEmpty) {
      return false;
    }
    try {
      return await channel.invokeMethod<Object?>('show', {
            'key': key,
            'title': title,
            'body': body,
            'lessonId': lessonId,
            'problemId': problemId,
          }) ==
          true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> cancel(String key) async {
    if (key.isEmpty) return;
    try {
      await channel.invokeMethod<void>('cancel', {'key': key});
    } on PlatformException {
      // A reminder failure must never interrupt classroom synchronization.
    } on MissingPluginException {
      // This platform does not provide local classroom notifications.
    }
  }

  Future<void> cancelAll() async {
    try {
      await channel.invokeMethod<void>('cancelAll');
    } on PlatformException {
      // Only this channel's reminder inventory is affected by cancellation.
    } on MissingPluginException {
      // This platform does not provide local classroom notifications.
    }
  }
}
