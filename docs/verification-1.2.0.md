# 1.2.0 验证记录

版本：1.2.0+23。

## 服务端适配

支持普通（`www.yuketang.cn`）、荷塘（`pro.yuketang.cn`）、长江（`changjiang.yuketang.cn`）和黄河（`huanghe.yuketang.cn`）。登录前选择服务端，三种登录方式使用同一选择；保存的登录凭证、本机答案、课堂 Bearer 与 WebSocket 按服务端隔离。

对照两个上游项目及四端公开页面验证接口与前端资源，证据见 [协议记录](protocol-evidence.md)。新增服务端尚未使用真实账号联调；公开入口、模拟接口测试不代表所有学校部署均已实测。

## 回归范围

- 服务端恢复、登录切换、迟到登录响应、退出与切换并发、同用户 ID 的答案隔离。
- API 主机、Cookie、课堂凭证与 WebSocket 地址隔离。
- 登录选择、三种登录方式、设置自动保存、手机手动浏览与教师翻页跟随。
- AI 全局串行请求、完成后间隔、重试次数、限流退避与取消，以及原有提交队列。

未操作真实设备或登录真实课堂。

最终全部 587 项 Flutter 测试通过；静态分析无问题，81 个 Dart 文件格式检查通过。源码公开检查未发现凭证、签名私钥或本机配置泄漏。

## 正式构建

正式构建源码：`bc05a216a109713f246beb610fa999493fc94a01`。Android 本地正式签名双包构建成功；[Windows / iOS CI](https://github.com/furryzirui/ykt_helper/actions/runs/45975178293) 成功，Windows 自启动授权检查通过。

- Android：核对 1.2.0+23、包名、单 arm64 与三架构通用包、原发布证书、v2 签名与 ZIP CRC。
- Windows：核对 1.2.0、PE/Inno 格式、x64 构建、运行依赖和 CI 28 项 authenticated 清单打包证据；未独立解包或运行安装器。
- iOS：核对 1.2.0+23、arm64、主程序未签名、ZIP CRC、Ed25519 清单签名及全部 50 项文件摘要。

| 安装包 | 字节 | SHA-256 |
| --- | ---: | --- |
| ykt_helper-1.2.0-android-arm64-v8a.apk | 28880680 | `f1cbcb05323144f1c5693d92575e51ff59e90d895fa1e450f4425eccc9a92613` |
| ykt_helper-1.2.0-android-universal.apk | 79151830 | `c2704f3f70e065b0889747806959396030f2862b4e0fcc60623992d43dd9511d` |
| ykt_helper-1.2.0-windows-setup.exe | 12478056 | `dbc8cad996035e8b1a14e883275de5088c36757304c2fd0daa0b76b485e40369` |
| ykt_helper-1.2.0-ios-unsigned.ipa | 9423179 | `2d7b332e697c44d74d1b333350474134f6de17118c11ab42f183dbe97d4be692` |
