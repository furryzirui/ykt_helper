# 1.1 验证记录

版本：1.1.0+16。Android 已由用户验收；Windows / iOS 完成本轮构建与安装包检查，未进行设备运行测试。

- 发布代码 CI 静态分析无问题，489 项 Flutter 测试通过，Windows 自启动另通过 81 项隔离注册表检查。
- 覆盖题目预生成、教师布置时间校正、逐题提交间隔、手动修改与提交、远端记录去重、位置签到轮次与授权确认、后台提醒、账号隔离、课件布局与跟随滚动。
- 已核实位置签到可以补足延迟的课堂报告；同课堂逐题提交同时满足布置后延迟和上一题成功后的间隔，结果不明时不盲目重试。
- 后台提醒仅在应用实际运行且系统允许通知时发送，不保证绕过系统挂起或通知限制。

[Windows / iOS CI](https://github.com/furryzirui/ykt_helper/actions/runs/44694080112) 和 [Android CI](https://github.com/furryzirui/ykt_helper/actions/runs/44694077370) 均通过，构建提交为 `cbffb85d68eccd246a33168095dea6c76a439515`。

## 安装包检查

Android 使用已验收的两个正式签名包，源码提交 `1e56bd5ebe532f3ce0130f5fc82958c682f3b576`；与本轮 CI 提交仅有文档差异。

- Android 已核对版本、包名、ABI、原发布证书、v2 签名与 ZIP CRC。
- Windows 已核对 EXE 格式、版本、x64 构建与签名清单打包记录；未运行安装器或本地解包核算内部文件。
- iOS 已核对 1.1.0+16、arm64、iOS 15 最低版本、主程序未签名、ZIP CRC、Ed25519 清单签名及全部 50 个文件摘要。

| 安装包 | 字节 | SHA-256 |
| --- | ---: | --- |
| ykt_helper-1.1.0-android-arm64-v8a.apk | 28684068 | `84bed9b98e8ae3c01f5c329b4d9c93b6d4524d5dbddefaa5c12114f685e7663e` |
| ykt_helper-1.1.0-android-universal.apk | 78463698 | `84a16a55f5bcd889997ed832414d0ddc8d33e16e9289ab8090c784dc368668a7` |
| ykt_helper-1.1.0-windows-setup.exe | 12417060 | `5f8e3af40f145f22e92d768888b4974971fa7a86db02cd1a89346a2da9a3f262` |
| ykt_helper-1.1.0-ios-unsigned.ipa | 9324491 | `41ad61b06637901e53e7d0685323a99caae5faad733081944e32b144f829681b` |
