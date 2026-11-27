# 构建说明

常规构建命令见根目录 README。当前版本 1.2.0+23，Android 包名 `com.furryzirui.ykt_helper`，最低 API 26，target/compile SDK 36。

## 发布签名

未配置发布签名时，`flutter build apk --release` 生成的是调试证书签署的优化测试包，供开发和 CI 使用。GitHub Release 的正式 APK 使用独立发布证书；两种签名不能覆盖安装，CI 产物也不能替代正式包更新。

自行分发时，创建自己的发布密钥，并在本地 `android/key.properties` 配置：

```properties
storeFile=../.signing/ykt_helper-release.jks
storePassword=<密钥库密码>
keyAlias=<密钥别名>
keyPassword=<密钥密码>
```

`storeFile` 相对 `android/` 根目录解析，也可以填写绝对路径。示例路径需与实际密钥库一致。配置完整时，Release 构建使用该发布证书；构建正式交付时应额外传入 `-PyktRequireReleaseSigning=true`，缺少发布签名将直接失败，避免误发调试签名包：

```sh
flutter build apk --release --config-only
cd android
./gradlew :app:assembleRelease -PyktRequireReleaseSigning=true
```

正式构建输出为 `build/app/outputs/apk/release/app-release.apk`。发布前核对 `apksigner verify --verbose --print-certs` 的证书摘要及 `aapt dump badging` 的包名和版本。

Release 分别提供 universal（三种 ABI）和 arm64-v8a 安装包。执行上述配置后，在 `android/` 目录分别构建并保存产物：

```sh
./gradlew :app:assembleRelease -PyktRequireReleaseSigning=true -Ptarget-platform=android-arm,android-arm64,android-x64 -Psplit-per-abi=false
./gradlew :app:assembleRelease -PyktRequireReleaseSigning=true -Ptarget-platform=android-arm64 -Psplit-per-abi=true -Pforce-version-code-ignoring-abi=true
```

arm64 产物为 `build/app/outputs/apk/release/app-arm64-v8a-release.apk`。保留同一 `versionCode`，使两种 APK 的后续更新规则一致。`--config-only` 只更新本地配置，ABI 参数需传给实际构建的 Gradle 命令。

本项目的发布私钥和密码只在本地保管，不提供给源码构建者。`.signing/`、`android/key.properties`、密钥库和密码不得加入 Git 或公开源码包。密钥持有人应分别备份私钥及其密码，后续正式更新使用同一证书；丢失后不能继续以原证书签名。

## 在 Windows 主机构建 Android

Windows 中文项目路径可能影响 Android Release 的 AOT 编译。可用 `subst` 将项目临时映射到空闲的 ASCII 盘符，然后在映射路径执行：

```powershell
flutter build apk --release --config-only --no-pub
```

再在该盘符的 `android` 目录执行：

```powershell
.\gradlew.bat :app:assembleRelease -PyktRequireReleaseSigning=true --no-daemon '-Pkotlin.incremental=false' '-Pkotlin.compiler.execution.strategy=in-process' --max-workers=4
```

结束后移除临时映射。关闭 Kotlin 增量编译可避免映射盘符与依赖缓存不同盘符导致的缓存错误。直接 Gradle 构建输出在 `build/app/outputs/apk/release/app-release.apk`。

JDK 若报 `Unable to establish loopback connection`，创建短路径临时目录，仅在当前 shell 将 `JAVA_TOOL_OPTIONS` 设为 `-Djdk.net.unixdomain.tmpdir=<绝对路径>` 后重试。不要把本机路径或代理凭证写入工程。

Windows 首次运行插件需要符号链接权限，可开启开发者模式；只做 Android 构建时也可按 Flutter 提示修复对应平台生成目录。Linux CI 无此 Windows 符号链接限制。

项目提供 CI 的分析、测试和调试签名 APK 构建，不自动创建 GitHub Release。CI 不持有正式发布私钥；CI、本机调试签名与正式签名可能不同，不应混用覆盖测试。

## Windows EXE 安装包

需要 Windows、Visual Studio C++ 桌面工具、Python 3 和 Inno Setup 6。在不含中文的项目路径执行：

```powershell
flutter pub get
flutter build windows --release
./scripts/windows/package.ps1
```

产物为 `dist/ykt_helper-1.2.0-windows-setup.exe`，包含 Flutter、原生插件、资源和 VC++ 运行库，每用户安装。脚本可用 `-InnoSetupCompiler` 指定现有 `ISCC.exe`。安装包未做 Authenticode 签名；登录安全验证需要 WebView2 Runtime。

## iOS 未签名 IPA

需要 macOS、Xcode、CocoaPods，最低 iOS 15：

```sh
flutter pub get
flutter build ios --release --no-codesign
bash scripts/ios/package_unsigned.sh
```

产物为 `dist/ykt_helper-1.2.0-ios-unsigned.ipa`。脚本验证真实设备 arm64、Bundle ID、版本、主应用未签名、无描述文件以及 ZIP 完整性。框架可能保留工具链签名，安装前需自行对完整应用签名；此流程不需要提供 Apple 账号或签名私钥。

仓库的 Windows / iOS 工作流使用对应系统构建并保存产物，不自动发布 Release。

运行完整性清单由打包脚本生成；官方 Windows / iOS 构建从 CI Secret 读取独立 Ed25519 密钥（需要 Python cryptography）。无签名密钥的自行构建版本仍可运行，但启动时会提示无法验证为官方发布。私钥不得加入源码。
