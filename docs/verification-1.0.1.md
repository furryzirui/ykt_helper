# 1.0.1 验证

版本：1.0.1+6；日期：2026-11-14；状态：发布构建已验证。应用代码来源：`9c9ffe1b465f589b0e0f8330c68e11276fb2cfd5`。

- 本地 215 项 Flutter 测试通过，静态分析无问题。覆盖服务启停、手动关闭后的防重启、设置保存、横屏分栏、选页与答案草稿保留，以及启动提示、完整性签名和文件变化检查。
- 手机 360×800、窄横屏 800×400、平板 1024×768、桌面 1280×800 及字号 1.0 / 1.5 进行了离线布局验证；设置项卡片宽度及备注检查通过。
- 横屏预览的题目标记和当前页保存通过回归测试及离线截图检查；覆盖独立/嵌入详情、宽/窄横屏、1.5 倍字体、切页后的保存目标、无图片页面和竖屏原有入口。
- Android 两种正式签名构建通过，均核验包名、1.0.1+6、最低 API 26、target API 36、发布证书、APK v2 签名和 ZIP CRC。arm64-v8a 包只含该架构；universal 包含 arm64-v8a、armeabi-v7a 和 x86_64，两包 versionCode 均为 6。
- [Windows / iOS 云端构建](https://github.com/furryzirui/ykt_helper/actions/runs/43590023378) 通过。Windows 为每用户 x64 安装包，已核对 PE、产品版本与 CI 中清单、WebView2 和 VC++ 运行库的打包记录；未独立解包重算 EXE 载荷。iOS 为 iOS 15+ arm64 未签名 IPA，已核对主应用未签名、无描述文件、ZIP CRC、Ed25519 清单签名及全部 50 个受校验文件的摘要，需自行签名安装。
- [Android 云端检查](https://github.com/furryzirui/ykt_helper/actions/runs/43590023357) 的分析、测试和构建通过；正式交付使用本地正式签名 APK，CI 测试包不替代正式包。

Android 核对已安装应用的发布证书。Windows / iOS 核对带 Ed25519 签名的文件清单及其摘要；iOS 对代码采用忽略正常重签元数据的摘要，并排除可被重签修改的签名目录、描述文件和 Info.plist。此检查用于发现发布身份或受校验文件不一致，不证明程序无法被逆向修改。

本轮未安装或操作目标设备，不含真实账号、课堂或长时间后台运行验收。用户完成此前测试后授权直接发布，最终横屏修正经过上述自动化及离线检查。[v1.0.1 Release](https://github.com/furryzirui/ykt_helper/releases/tag/v1.0.1) 仅附两个 APK、Windows EXE 和 iOS IPA，四个文件的 SHA256 写在 Release 说明中。
