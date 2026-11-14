# 构建说明

常规构建命令见根目录 README。Android 包名 `com.furryzirui.ykt_helper`，最低 API 26，target/compile SDK 36。

Windows 中文项目路径可能影响 Android Release 的 AOT 编译。可用 `subst` 将项目临时映射到空闲的 ASCII 盘符，然后在映射路径执行：

```powershell
flutter build apk --release --config-only --no-pub
```

再在该盘符的 `android` 目录执行：

```powershell
.\gradlew.bat :app:assembleRelease --no-daemon '-Pkotlin.incremental=false' '-Pkotlin.compiler.execution.strategy=in-process' --max-workers=4
```

结束后移除临时映射。关闭 Kotlin 增量编译可避免映射盘符与依赖缓存不同盘符导致的缓存错误。直接 Gradle 构建输出在 `build/app/outputs/apk/release/app-release.apk`。

JDK 若报 `Unable to establish loopback connection`，创建短路径临时目录，仅在当前 shell 将 `JAVA_TOOL_OPTIONS` 设为 `-Djdk.net.unixdomain.tmpdir=<绝对路径>` 后重试。不要把本机路径或代理凭证写入工程。

Windows 首次运行插件需要符号链接权限，可开启开发者模式；只做 Android 构建时也可按 Flutter 提示修复对应平台生成目录。Linux CI 无此 Windows 符号链接限制。

项目提供 CI 的分析、测试和 APK 构建，不自动创建 GitHub Release。CI 调试签名与本机调试签名不同，不应混用覆盖测试。
