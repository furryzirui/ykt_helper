# 平台准备

应用名：`ykt_helper`；当前版本 1.0.0+5，目标 Android 8.0+，最低 SDK 26。仅适配普通雨课堂 `www.yuketang.cn`。

| 平台 | 标识 | 当前状态 |
| --- | --- | --- |
| Android | `com.furryzirui.ykt_helper` | 本轮目标；原生相册、权限和后台模块已实现，本轮不真机验收 |
| iOS | `com.furryzirui.ykt-helper` | 工程准备；尚未完成 Xcode 构建、签名和真机适配 |
| Windows | `ykt_helper` 工程 | 工程准备；尚未完成缺失插件及目标平台构建验证 |

Android 包名与早期 `com.furryzirui.rain_classroom` 测试包不同，新旧应用独立安装、独立存储。1.0.0 起又改用独立正式发布签名，不能覆盖同包名的调试测试版；需卸载测试版再安装，重新登录和设置。正式发布私钥、密码及 `.signing/` 仅在本地保管，不纳入仓库或源码包。后续正式版本沿用该发布签名。

| 模块 | 共用实现 | 后续原生工作 |
| --- | --- | --- |
| 课程/历史/答案/签到 | Dart + Dio；账号 Cookie 和课堂 Bearer 分离；列表独立读取签到状态 | 检查目标平台 TLS、网络代理、安全存储及报告时机 |
| 实时课堂 | dart:io WebSocket；按账号和课堂独立连接 | Windows 生命周期；iOS 暂停/恢复时重连 |
| AI 与自动化 | 独立 HTTP 客户端、OpenAI 兼容图文消息；二级设置和明确保存 | 按设备内存调整缓存，不改变用户选择的课件范围 |
| 设置和账号 | Flutter 安全存储、三种登录方式 | Windows Credential Manager、iOS Keychain 验证 |
| 日志 | 有界事件白名单、应用支持目录持久化、等待初始化后导出 TXT | 各平台存储路径、文件分享/保存对话框验证 |
| 布局与关于 | Flutter Material 3、二级设置导航、仓库外部链接 | Windows 大窗口和键盘交互，外部浏览器验证 |
| 安全验证 | Android/iOS WebView；凭证由 Dart 提交 | Windows 增加 WebView2，当前可用二维码替代 |
| 扫码与图片 | mobile_scanner/image_picker；课程/动态统一扫码入口 | iOS 相机/相册用途说明与设备验证，Windows 可输入二维码内容 |
| 导出 | ZIP / 图片版 PPTX 共用 | 分享和保存对话框差异；低内存设备流式导出 |
| 相册保存 | `GallerySaver`；Android MediaStore / 旧系统公共 `Pictures/ykt_helper` | iOS PhotoKit 授权及写入，Windows 保存文件对话框 |
| 权限管理 | `AppPermissions` 状态/申请/设置接口；Flutter 用途、步骤和确认页 | Android 相机/通知优先单项弹窗；其他平台暂不支持，后续接原生实现 |
| 后台 | Android foreground specialUse 服务、CPU/WiFi 锁及通知 | Windows 托盘/休眠恢复；iOS 重新设计受系统允许的后台方式 |

`BackgroundRuntime` 启动前只读取通知及标准电池优化豁免，不自行申请授权。用户确认用途和步骤后，`AppPermissions` 才请求相机、通知或旧系统存储弹窗；不能弹窗时回退本应用设置。电池管理统一进入单应用详情，不依赖小米私有组件，不按已授权/未授权切换到不同列表。厂商后台、自启动及电池管理并无统一公开接口，仍需目标设备验证。

Android 13+ 才提供通知运行时授权弹窗；较低版本使用本应用通知设置，通知类别被关闭时也需要在系统设置恢复。当前权限和后台模块的自动化测试使用模拟平台通道，原生弹窗及厂商路由仍需真机确认。

Android 10+ 相册只写入应用新增图片，无需读取相册权限。日志只接受固定事件枚举及数字结果，不接收请求头、URL、账号或题目答案。原生存储、扫码、权限和 WebView 均由模块边界隔离，业务层不依赖 Activity。

当前 Windows 主机不能验证 iOS Xcode 编译、签名、Keychain entitlement 和后台行为，需在 macOS 上完成。工程目录和标识已准备不等于所有平台已经适配。
