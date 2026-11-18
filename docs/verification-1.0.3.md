# 1.0.3 验证记录

版本：1.0.3+15。

- 静态分析无问题，419 项 Flutter 测试通过；Windows 自启动通过 81 项隔离注册表检查，Android 截止时间与启动策略通过 38 项 Kotlin 检查。
- 覆盖新服务恢复“永不”、运行中手动倒计时保留、自动启动与定时互斥、手动停服限制、旧到期回调防护、旧配置修正、进程恢复及前后台到期差异。状态读取失败不会被当成服务已关闭。
- iOS 保留静音音频、画中画和持续定位，已移除长任务方案及临时每 10 秒诊断日志；普通应用日志仍保留。用户已完成三种保活方案的设备测试。
- 到期处于前台时 Android/iOS 停止系统服务，Windows 保持运行；处于后台时 Android/Windows 退出，iOS 停止保活和自动化，由系统挂起。

本轮未安装或操作设备，发布包的后台耗电、系统中断及真实课堂表现未重新实测；检查步骤见 [iOS 后台运行](ios-background-testing.md)。

## 安装包检查

安装包源代码提交：`df1cc507e39296007fc44536c009f1ebee418295`。[Windows / iOS CI](https://github.com/furryzirui/ykt_helper/actions/runs/44329122573) 与 [Android CI](https://github.com/furryzirui/ykt_helper/actions/runs/44329116338) 均通过。

- Android 两个 APK 已核对 1.0.3+15、包名、架构、原发布证书、v2 签名及 ZIP CRC。
- Windows 已核对安装器格式、版本和 CI 打包证据；未执行安装器或本地解包核算内部文件。
- iOS 核对 1.0.3+15、arm64、iOS 15 最低版本、主程序未签名、ZIP CRC、Ed25519 清单签名与全部 50 个文件摘要；后台声明仅 audio/location，不包含长任务白名单。

| 安装包 | SHA-256 |
| --- | --- |
| Android arm64-v8a | `befc07096c62b7f03fb857da3cdf155c138c172aa62de6da310e94464f6e410e` |
| Android universal | `489476ef900e0c015097de6a38c700d5c929195b325c1a8645eb0c8e8b1b88d3` |
| Windows EXE | `acd43db7c7be7bff5a6123c211a3f4f044aad0cfc4416393fd4873843f5ef14c` |
| iOS unsigned IPA | `a414c9bcaf193812e7521c8496432ba0b4f4f1c160fe6dff150ee3f58a395f2f` |
