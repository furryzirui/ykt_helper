import 'package:flutter/material.dart';

import '../domain/models.dart';

String backgroundServiceModeLabel(BackgroundServiceMode mode) => switch (mode) {
  BackgroundServiceMode.native => '系统默认',
  BackgroundServiceMode.silentAudio => '静音音频保活',
  BackgroundServiceMode.pictureInPicture => '画中画保活',
  BackgroundServiceMode.location => '持续定位保活',
};

Future<bool> confirmIosBackgroundService(
  BuildContext context,
  BackgroundServiceMode mode, {
  bool starting = true,
}) async {
  final details = switch (mode) {
    BackgroundServiceMode.silentAudio =>
      '将循环播放静音音频以尝试维持后台运行，可能增加耗电。来电、其他音频、蓝牙切换或音频会话中断可能使服务停止。',
    BackgroundServiceMode.pictureInPicture =>
      '将开启画中画浮窗以尝试维持后台运行。关闭浮窗、锁屏、系统回收或其他播放器可能使服务停止；请保持浮窗开启。',
    BackgroundServiceMode.location =>
      '将持续使用设备定位以尝试维持后台运行，可能明显增加耗电并显示定位指示。需要允许后台定位；定位服务关闭、权限变化或系统暂停定位可能使服务停止。定位数据不会用于课堂签到或上传。',
    BackgroundServiceMode.native => '当前模式不能保证 iOS 持续后台运行。',
  };
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(backgroundServiceModeLabel(mode)),
          content: SingleChildScrollView(
            child: Text(
              '$details\n\n此功能为实验性适配，无法保证整节课持续运行。手动清除应用、重启、低电量、系统资源限制及网络中断都可能影响自动化；服务停止后仅前台运行。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(starting ? '确认开启' : '确认选择'),
            ),
          ],
        ),
      ) ??
      false;
}
