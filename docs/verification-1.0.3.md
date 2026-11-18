# 1.0.3 测试记录

版本：1.0.3+13；状态：待用户验收，未发布 Release；稳定版仍为 1.0.2。

后续 iOS 诊断测试包更新为 **1.0.3+14**，包含临时日志；前一批三平台安装包记录保留如下。

- 静态分析无问题，397 项 Flutter 测试通过；Windows 自启动通过 81 项隔离注册表检查，Android 截止时间与退出策略通过 26 项 Kotlin 检查。
- 测试覆盖定时重选、绝对截止、进程恢复、前后台到期差异、恢复窗口时取消退出，以及停服后暂停后台自动化。恢复课堂时重新同步状态，丢弃挂起前迟到的课件和 AI 结果。
- iOS 提供静音音频、画中画、持续定位和 iOS 26 长任务实验方案；定位先保存方案，开启前授权。开启服务、启用自动启动及修改方案均需确认相关限制。
- iOS 26 方案每次前台手动启动，必须设置结束时间，不能自动启动或取消后自行重提。进度表示实际经过的会话时间，不保证运行满所选时长。
- 到期处于前台时，Android/iOS 停止系统服务，Windows 保持运行；处于后台时 Android/Windows 退出，iOS 停止保活和自动化后交给系统挂起。

本轮未安装或操作设备；iOS 后台实际执行、耗电、系统中断及真实课堂行为仍需真机测试，步骤见 [iOS 后台验收](ios-background-testing.md)。本次不提供 TrollStore 或越狱方案。

## 安装包检查

安装包源代码提交：`e718a9665dde8d6104eef42c253af365a5eb7c9d`。[Windows / iOS CI](https://github.com/furryzirui/ykt_helper/actions/runs/44263402097) 与 [Android CI](https://github.com/furryzirui/ykt_helper/actions/runs/44263399782) 均通过。

- Android 两个 APK 已核对版本、包名、架构、原发布证书、v2 签名及 ZIP CRC。
- Windows 已核对安装器格式、版本及 CI 打包证据；未执行安装器或本地解包核算内部文件。
- iOS 使用 Xcode 26 编译，核对 1.0.3+13、arm64、iOS 15 最低版本、主程序未签名、后台声明、ZIP CRC、清单签名及全部 50 个文件摘要。

| 安装包 | SHA-256 |
| --- | --- |
| Android arm64-v8a | `e4c0940c1935db26788c100e38e1015e402b72e2e1cd0f7ebbde4b067a49bc3e` |
| Android universal | `c08849dd5b61dc3dc04bcf16f83eba2566a530243a0282e4c72814a3d9088f05` |
| Windows EXE | `9cc8cc4e9a317fc606bd14bb9e975526cafc36629c4a0516ea77f15eb08be1bd` |
| iOS 未签名 IPA | `7728cba8c63f3ed382218adfd21b7662ebccdb7cb0c7fff512c3295ae815918b` |

## iOS 诊断测试包 1.0.3+14

- 用户确认自行签名时修改了 Bundle ID。原 IPA 的任务白名单仍包含原 Bundle ID，若签名工具未同步该数组，运行时注册标识会与白名单不匹配。现已增加配置预检及系统错误原因显示，不再一律返回通用启动失败；签名前同步字段的步骤见 [iOS 后台验收](ios-background-testing.md)。
- 每 10 秒实际执行 Dart 心跳并读取音频或画中画状态，不补造挂起期间的历史采样。超时、停服和旧会话快照不会作为新采样复用；只读诊断不改变服务状态。仅测试构建开启，正式构建默认关闭并过滤旧测试事件。
- 静态分析、419 项 Flutter 测试通过；最后一处迟到快照保护另通过 32 项相关测试。[最终代码 CI](https://github.com/furryzirui/ykt_helper/actions/runs/44316160427) 全量检查通过，[iOS 构建](https://github.com/furryzirui/ykt_helper/actions/runs/44316170541) 的签名配置策略测试与 Xcode 编译通过，日志确认测试开关为 `true`。
- 核对 1.0.3+14、arm64、主程序未签名、ZIP CRC、清单签名及全部 50 个文件摘要；未安装设备或验证实际后台行为，未创建 Release。

安装包源代码提交：`f8c64d3c094c67d95d77fea88ae7303003b3b614`；本地文件名：`ykt_helper-1.0.3-build14-ios-background-test-unsigned.ipa`；SHA-256：`3842546679cb98cde7819d1f42dceec23b3dffe55bb533830bccdeccb67326b4`。
