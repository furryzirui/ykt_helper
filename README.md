# ykt_helper

普通版雨课堂的非官方辅助工具，使用 Flutter 开发。目前提供 Android 8.0+ 支持，Windows / iOS 工程已预留，尚未完成适配。项目与雨课堂官方没有关联。

仓库：[furryzirui/ykt_helper](https://github.com/furryzirui/ykt_helper) · 开发者：**紫锐飞跃** · 许可证：[GPL-3.0](LICENSE)

## 功能

- **课程**：在读和归档课程、历史课堂分页；列表直接显示签到状态，未读到报告时明确显示未同步。课堂详情直接展示签到信息、回顾课件和本人答案。
- **动态**：正在上课的课堂、签到入课、教师翻页同步、本人答案恢复及各题型作答。课程和动态右上角均提供扫码入口。
- **自动化**：自动签到、固定内容或自定义 AI 作答、自动提交开关。关闭自动提交时只填入可编辑答案，确认后手动提交。
- **AI**：OpenAI 兼容接口，自动获取模型列表、自定义提示词，以及不发课件/当前页/当前和后一页/完整课件四种范围。
- **课件**：单页或全部图片保存到系统相册；ZIP、完整图片版 PPTX 导出后打开系统分享面板。
- **设置**：二维码、短信验证码、账号密码三种登录；应用权限管理、自动化二级菜单、本机日志查看和 TXT 文档导出、关于。
- **后台**：经用户开启自动化后，使用 Android 前台服务和常驻通知维持连接。厂商省电限制仍可能影响后台运行。

只适配 `www.yuketang.cn` 普通版。旧版课堂详情、其他雨课堂平台、课堂回放不在当前支持范围。

## 使用

在设置中登录，进入“自动化”编辑设置，并点击“保存设置”。自动签到、自动答题、自动提交默认关闭；已有设置沿用其保存状态。自动签到会发送入课签到请求。

课程和动态右上角的扫码按钮用于进入课堂。历史课堂列表中的签到标记来自课堂报告，不能把接口未就绪当成未签到。位置签到使用服务端中心坐标，显示地址及坐标并经用户确认后提交，不代表手机实测定位。

应用权限页先显示权限用途和操作步骤，经确认后请求单项授权；无法直接授权时再进入系统设置。Android 10+ 保存本应用下载的课件无需读取相册权限。后台运行需要通知及电池优化豁免，正常状态不额外显示说明，只在异常时提示。

当前不发布 GitHub Release；可自行构建。详细手机验收步骤见 [Android 联调](docs/android-validation.md)。

## AI 配置

填写服务商的 OpenAI 兼容 `base_url` 和 `api_key`，例如 `https://api.example.com/v1`。应用通过 `GET <base_url>/models` 获取模型选项，通过 `POST <base_url>/chat/completions` 作答。选择附带课件或题目本身包含图片时，需要使用支持图像输入的模型。

默认提示词：

```text
请使用最简洁的回答完成这道题：{question}
```

`{question}` 替换为题干及选项。没有该占位符时会追加题目；发送课件时补充“可以参考课程课件进行完成”。课件范围按题目所在页确定；题目附图始终作为题目发送。完整课件超过 40 MB 时提示减少范围，不静默截断。

AI 请求独立认证，雨课堂 Cookie 不会发送给 AI 服务。启用前应自行确认模型服务商、费用和允许发送的课件范围。设置变化、题目关闭、已有答案、生成失败或课堂结束时不会继续自动提交；提交响应不确定时先同步远端结果。

## 数据与日志

账号 Cookie、AI 密钥、设置和本机答案通过系统安全存储保存。退出登录清除当前账号状态及本机答案。课件导出文件由用户管理。

应用日志仅在本机保留最近 500 条操作事件，可在设置“应用日志”查看并导出 TXT。记录操作类型、结果、数字状态码，不记录请求头、Cookie、密钥、账号身份、二维码内容、题目、课件内容或答案。日志不会自动上传。

公开仓库不包含个人账号、设备截图、真实课件、凭证、签名私钥、SDK 配置或本地构建缓存。提交问题时也不要粘贴这些内容。

## 本地构建

环境：Flutter 3.50.0 / Dart 3.14.0、JDK 21、Android SDK 36，最低 Android API 26。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

输出为 `build/app/outputs/flutter-apk/app-release.apk`。包名：`com.furryzirui.ykt_helper`。本次包名调整不迁移此前测试应用的数据，需要重新登录和设置。默认 Android 工程使用调试证书签署优化后的 Release 测试包；正式分发应自行配置并妥善保存发布证书。不同证书签名的包不能直接覆盖。

不要提交 `android/local.properties`、`android/key.properties`、签名文件或任何凭证。Windows 中文路径及本机 JDK 的构建注意事项见 [构建说明](docs/build.md)。

## 项目结构

```text
lib/domain/      数据模型和应用信息
lib/data/        HTTP、Cookie、WebSocket、安全存储
lib/app/         课堂事件、答题状态、自动化与账号隔离
lib/services/    AI、课件导出、相册、权限、后台和本机日志
lib/ui/          课程、动态、设置及二级页面
android/        Android 工程与原生平台实现
windows/ ios/   后续平台工程
test/          协议、并发、自动化、界面及服务测试
docs/          协议证据、验证边界和适配说明
```

测试使用模拟协议数据和离线布局样本，不代表所有真实课堂及厂商系统都已验证。本轮按用户要求不使用 ADB 或操作手机。当前验证结果见 [验证记录](docs/verification.md)，后续平台边界见 [平台准备](docs/platforms.md)。

## 参考与许可证

参考 [AneryCoft/course_helper](https://github.com/AneryCoft/course_helper)、[FirmPluvia/ykt_assistant](https://github.com/FirmPluvia/ykt_assistant)，并核对普通版官方公开前端接口。参考提交和字段证据见 [协议证据](docs/protocol-evidence.md)。未将未提供 LICENSE 的 `ykt_assistant` 源码纳入本仓库；依赖组件保留各自许可证。

Copyright (C) 2026 紫锐飞跃。项目按 **GNU General Public License v3.0** 开源，详见 [LICENSE](LICENSE)。GPL 允许修改、再分发和商业销售；分发衍生程序时须遵守对应源码和许可证要求。本项目不额外限制 GPL 赋予的权利。
