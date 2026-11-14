# 本轮验证

日期：2026-11-14；版本：1.0.0+5；应用：`ykt_helper`。本轮按用户要求不使用 ADB、不安装或操作手机。

Android 包名：`com.furryzirui.ykt_helper`；iOS Bundle ID：`com.furryzirui.ykt-helper`。1.0.0 使用独立正式签名，不能覆盖此前同包名的调试签名测试包，需要卸载后重新安装、登录和设置。

| 验证 | 结果 / 覆盖范围 |
| --- | --- |
| Flutter 静态分析 | 完整 `flutter analyze --no-pub` 通过，无问题 |
| 全部本地测试 | 157 项通过，包含提交延迟、AI 生成中编辑、迟到远端结果、取消与失败状态，以及跨平台权限、目录保存和验证码协议 |
| HTTP 协议 | 普通版认证、教学班关联、归档及历史分页、旧版标记、独立签到报告、本人答案和提交 |
| 自动答题与课堂事件 | 固定/AI 仅填充、手动确认、默认 30 秒提交延迟、迟到结果、重复事件、收题、时限和课件更新 |
| 账号隔离 | 切换账号和课堂时的迟到结果、已有答案恢复和课件同步 |
| AI 与自动化设置 | 模型发现、自定义/默认提示词、四种课件范围、图题、严格解析、保存失败不生效、二级菜单及草稿 |
| 登录界面 | 三种方式同排、短信/密码字段切换、秘密输入清理、迟到二维码不恢复 |
| 课堂列表与扫码 | 列表已签到/未签到/未同步状态、签到读取并发限制、账号与刷新隔离、课程/动态右上角扫码 |
| 日志 | 枚举/数字白名单、持久化和恢复、500 条边界、损坏条目处理、TXT 导出等待初始化及存储失败 |
| 权限与后台服务 | Dart 通道和模拟结果测试：单项请求、状态映射、平台边界、异常、后台纯检查及禁用插件自行授权；Android 原生弹窗和设置路由仅代码审查 |
| 权限页面 | 用途与步骤、确认才申请或跳转、取消零跳转、恢复前台重查、无需授权及错误提示 |
| 相册与导出 | PNG/JPEG 原图、按页保存、无图页、部分失败数量、ZIP/OpenXML 结构、Windows 目录选择/取消/文件写入及平台边界；iPad 分享位置代码审查 |
| 布局 | 360×800、字号 1.0 / 1.5 共 8 项离线检查通过，已查看生成的课程、课堂列表、回顾与自动化布局；图标正常加载 |
| Android Release | 强制正式签名构建成功；包名 `com.furryzirui.ykt_helper`、版本 1.0.0+5、min 26 / target 36、arm64-v8a / armeabi-v7a / x86_64 均经 `aapt` 核验，`apksigner` v2 验证通过，证书为独立 RSA 3072 发布证书 |

初次 GitHub 检查在界面测试滚动后误点屏幕外按钮。修复后，[完整云端检查](https://github.com/furryzirui/ykt_helper/actions/runs/43535050232) 已通过测试、Android 构建及产物上传。普通测试统一使用 Flutter 默认测试字体，滚动后等待布局并验证按钮可点击；可选截图仍可使用本机中文字体。

自动化测试使用模拟响应或本地文件，不使用个人账号，不含真实课件、答案或凭证。权限测试模拟平台通道返回，不能证明 Android 系统实际出现了授权弹窗或厂商设置打开了指定页面。离线布局截图位于被 Git 忽略的 `.workspace-bootstrap/qa/`，不是应用内演示数据，也不随源码或 APK 分发。

用户反馈此前手机测试未发现问题，未逐项记录覆盖范围。本轮由开发环境进行本地测试、代码审查和编译校验。新增延迟、单项授权弹窗、系统设置跳转、Android 8–9 相册权限、通知类别恢复、厂商电池开关和真实课堂事件的目标设备表现仍需按联调清单验证。公开仓库及交付包排除凭证、本机 SDK 配置、签名私钥、设备截图、参考仓库和构建缓存。

此前 0.1.1 的 Android 16 真机检查见 [历史验收记录](device-validation-2026-11-14.md)，不作为 1.0.0 新功能及正式签名的真机证明。三种真实登录流程、进行中课堂答案同步及自动填充、签到报告时机、位置签到、AI 作答和长时间锁屏事件的详细覆盖见 [Android 联调步骤](android-validation.md)。

iOS 已在 [macOS CI](https://github.com/furryzirui/ykt_helper/actions/runs/43540203991/job/132278728534) 完成 Swift 编译、`flutter build ios --release --no-codesign` 和 IPA 打包。下载后再次核验 ZIP CRC、Bundle ID、1.0.0+5、最低 iOS 15、iphoneos / arm64，以及主程序无 `LC_CODE_SIGNATURE` 和无描述文件。内嵌框架仅保留工具链 ad-hoc 签名，无 Apple 开发者证书。安装前需自行签名，未验证 iPhone/iPad 上的运行、Keychain、权限弹窗或真实课堂；系统挂起后不保证自动化运行。

Windows 已在 [Windows CI](https://github.com/furryzirui/ykt_helper/actions/runs/43541107263/job/132281621837) 完成 x64 Release 编译及 Inno Setup 打包。修复 MSVC 对 WebView2 插件实验性协程的兼容限制，并补入必需的 `WebView2Loader.dll`；打包记录确认包含该文件和 VC++ 运行库。下载后检查 MZ/PE、Inno 数据头及产品版本 1.0.0，安装器为 32 位引导程序、应用为 x64。未运行安装器，也未验证真实登录、安全存储、分享面板或课堂事件。

包含最终代码的 [Android 云端检查](https://github.com/furryzirui/ykt_helper/actions/runs/43541107227) 已通过分析、测试、构建和产物上传；CI 的 APK 为调试证书测试包，Release 使用本地强制正式签名构建的 APK。

交付 APK、源码及校验和将随 [v1.0.0 Release](https://github.com/furryzirui/ykt_helper/releases/tag/v1.0.0) 提供。正式证书 SHA-256：`a1a111e5df677fd367379bafe5846fdb4ef7afcc80d16cd9bbec002a0d2cb8c3`。源码不包含发布私钥和密码。

APK：77,270,318 字节，SHA-256 `921fe3a5c4a0b518be2e3271a2be4571817bce2d1fc5a762b849a10db69cc203`。EXE：12,281,012 字节，SHA-256 `99146fb4d4e02a1193cd3fc21842a501d8c3e152881253c41fcb25c9c4a31998`。IPA：9,049,419 字节，SHA-256 `1eed36000b2e6bdec2c9dde44c7869c3f520cb8dceffae693ef47f470936daf0`。最终文件及其校验和见 Release；`BUILD-INFO-1.0.0.txt` 记录各平台构建来源。
