# 1.0.0

版本：1.0.0+5；日期：2026-11-14。

- 发布 Android APK、Windows x64 EXE 安装包和 iOS arm64 未签名 IPA，保留课程、课堂回顾、签到与作答、自动化、课件保存与导出、权限管理、本机日志及关于页。
- Android 包名为 `com.furryzirui.ykt_helper`，iOS Bundle ID 为 `com.furryzirui.ykt-helper`。
- 改用独立正式发布签名，后续正式更新沿用。此前调试签名的测试版需先卸载，再安装正式版并重新登录、设置；签名私钥和密码不公开。
- 自动提交开启后显示“提交延迟”，默认 30 秒，可修改秒数。答案准备好后再开始等待；等待期间收题、下课、切换账号或设置变化会取消本次自动提交。手动提交不受延迟影响。
- 补齐 Windows WebView2 安全验证与图片目录保存、iOS 原生权限和相册写入，并修正 iPad 分享位置。Windows 自动化需保持应用运行，iOS 需保持前台。
- 修正离线界面测试在 Linux 下的滚动点击：滚动后等待重新布局，确认按钮可点击再加载后续课堂。普通测试统一使用 Flutter 测试字体，中文字体仅用于可选截图。应用业务行为不受此测试修正影响。

[下载 v1.0.0](https://github.com/furryzirui/ykt_helper/releases/tag/v1.0.0)。GitHub Actions 提供分析、测试和调试签名测试包，不自动发布正式版本；正式 Release 的 APK 使用独立发布签名。

用户反馈手机测试未发现问题，未逐项记录测试覆盖范围。本轮未安装或操作目标设备；三种真实登录、真实课堂事件、各题型和厂商系统的详细验收范围见 [Android 联调清单](android-validation.md)。本地及云端检查结果见 [验证记录](verification.md)。iOS IPA 需要自行签名后安装。
