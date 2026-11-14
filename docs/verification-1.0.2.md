# 1.0.2 验收记录

版本：1.0.2+7；日期：2026-11-14；状态：待用户验收，不发布 Release。代码提交：`63b74b3d35f9851a5c042a384a8f92d4ccddf100`。

- 本地 276 项 Flutter 测试通过，静态分析无问题。新增覆盖三类固定答案、旧配置迁移、课件额外提示词、应用自启动条件、保存失败回滚、并发保存、断网登录恢复及退出后的迟到响应隔离。
- 扫码测试覆盖扫描范围、双指变焦、相机控制、权限确认、生命周期、重复识别及销毁。手机 360×800、横屏 800×400、字号 1.0 / 1.5、键盘和 Windows 进行了离线截图检查。
- Android 两个正式签名 APK 均核对包名、1.0.2+7、最低 API 26、target API 36、独立发布证书、v2 签名、ZIP CRC 和实际架构；arm64 包仅包含 arm64-v8a，universal 包包含三种 ABI。
- Windows 原生修改通过 MSVC `/W4 /WX` 编译检查。[Windows / iOS CI](https://github.com/furryzirui/ykt_helper/actions/runs/43598884816) 与 [Android CI](https://github.com/furryzirui/ykt_helper/actions/runs/43598882714) 的完整构建均已通过。
- 下载后核对 Windows 安装器的 PE、版本和 CI 载荷打包证据，未独立解包重算 EXE 内容。iOS IPA 的版本、arm64、主应用未签名、ZIP CRC、Ed25519 清单签名及全部 50 个受校验文件的摘要均通过核验。

本轮未安装或操作目标设备。Android 开机、系统进程回收和厂商自启动授权、扫码实际识别与相机变焦，Windows 登录启动及托盘行为，以及 iOS 权限和扫码，需要用户在目标设备验收。Android 没有统一的厂商自启动授权查询接口，权限页显示需要系统确认；强行停止和厂商限制可能阻止恢复。iOS 不提供应用自启动。

稳定版仍为 1.0.1。验收包位于本地 `dist/`，与 Release 隔离；通过验收后再合并和发布。
