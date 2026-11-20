# ykt_helper

普通版雨课堂辅助工具，支持 Android、Windows 和 iOS。

**稳定版 1.1.1** · [下载安装包](https://github.com/furryzirui/ykt_helper/releases/latest) · [GPL-3.0](LICENSE)

## 功能

- 课程与历史课堂列表、签到状态、课堂回顾和本人答案。
- 实时课堂、扫码入课、签到、课件同步与各题型作答。
- 自动签到与位置签到、固定内容或自定义 AI 答题；可选择仅填充或逐题自动提交，提交间隔默认 30 秒。
- AI 模型自动获取、自定义提示词及课件发送范围。
- 课件图片保存相册，ZIP / 完整图片版 PPTX 导出。
- 三种登录方式、权限设置、本机日志查看与导出。
- 应用自启动：Windows 登录启动，Android 在系统允许范围内开机恢复自动化。
- 定时关闭后台服务；iOS 支持静音音频、画中画和持续定位后台方案。
- 后台题目需要手动作答、确认提交或处理失败时提醒。

## 使用

安装后在“设置”登录；设置修改后自动保存。自动签到、自动答题和自动提交默认关闭。

Android 8.0+ 推荐选择较小的 `arm64-v8a.apk`，其他架构选择 `universal.apk`；后台运行需开启系统服务、允许通知并调整电池优化。Windows 10 1809+ x64 提供 EXE 安装包；iOS 15+ 提供未签名 IPA，需自行签名后安装。iOS 后台方案在系统允许范围内运行，定位方案需要“始终允许”；Windows 需保持应用运行。

AI 使用 OpenAI 兼容服务，填写 `base_url`、`api_key` 后选择模型；发送图片需使用支持图像输入的模型。

仅适配 `www.yuketang.cn` 普通版。自动签到包含位置签到，开启时确认使用服务端中心坐标，手动签到逐次确认。详细日志包含题目、AI 回复和本人答案，导出前请确认分享范围。

## 构建

Flutter 3.50.0 / Dart 3.14.0；Android 另需 JDK 21 和 Android SDK 36。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

各平台构建及签名见 [构建说明](docs/build.md)，测试范围见 [验证记录](docs/verification-1.1.1.md)。请勿提交账号凭证或签名私钥。

## 许可证

Copyright (C) 2026 紫锐飞跃，按 [GPL-3.0](LICENSE) 开源。
