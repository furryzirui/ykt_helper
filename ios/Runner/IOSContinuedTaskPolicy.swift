import Foundation

/// Kept free of UIKit/BackgroundTasks so signing configuration and safe error
/// reporting can be exercised on macOS without launching an iOS application.
struct IOSContinuedTaskFailure: Error {
  let reason: String
  let message: String
}

enum IOSContinuedTaskPolicy {
  static let schedulerErrorDomain = "BGTaskSchedulerErrorDomain"

  static func identifierPrefix(bundleIdentifier: String?, permittedIdentifiers: [String]?) throws -> String {
    guard let identifier = bundleIdentifier, !identifier.isEmpty,
          identifier.utf8.count <= 255,
          identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
          identifier.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...90).contains($0.value) ||
              (97...122).contains($0.value) || $0.value == 46 || $0.value == 45
          }) else {
      throw IOSContinuedTaskFailure(
        reason: "continuedInvalidBundleIdentifier",
        message: "无法读取有效的应用 Bundle ID，请重新签名安装后重试"
      )
    }
    let prefix = identifier + ".classroomMonitoring."
    let wildcard = prefix + "*"
    guard permittedIdentifiers?.contains(wildcard) == true else {
      throw IOSContinuedTaskFailure(
        reason: "continuedIdentifierMismatch",
        message: "后台任务标识与签名后的 Bundle ID 不一致。请保留原 Bundle ID 重新签名，或将 BGTaskSchedulerPermittedIdentifiers 同步为 \(wildcard) 后再签名"
      )
    }
    return prefix
  }

  static var busy: IOSContinuedTaskFailure {
    IOSContinuedTaskFailure(reason: "continuedBusy", message: "限时课堂监控正在启动或运行，请先停止已有任务")
  }

  static var registrationRejected: IOSContinuedTaskFailure {
    IOSContinuedTaskFailure(
      reason: "continuedRegistrationRejected",
      message: "系统未能注册限时课堂监控；请检查签名后 Info.plist 的后台任务白名单与 Bundle ID 是否一致"
    )
  }

  static func failure(for error: Error) -> IOSContinuedTaskFailure {
    if let failure = error as? IOSContinuedTaskFailure { return failure }
    let nsError = error as NSError
    // Never forward arbitrary localizedDescription/userInfo: a framework error
    // can contain paths, identifiers or other unrelated diagnostic information.
    guard nsError.domain == schedulerErrorDomain else {
      return IOSContinuedTaskFailure(reason: "continuedSubmitFailed", message: "系统未能提交限时课堂监控任务，请稍后手动重试")
    }
    let message: String
    switch nsError.code {
    case 1:
      message = "系统未允许后台任务，请检查后台 App 刷新是否开启，并在真机上重试"
    case 2:
      message = "待运行的后台任务过多，请先结束已有任务后重试"
    case 3:
      message = "系统未授权此后台任务，请检查后台声明、签名后的任务标识和系统后台限制"
    case 4:
      message = "系统当前不允许立即运行限时课堂监控，请稍后手动重试"
    default:
      message = "系统未能提交限时课堂监控任务，请稍后手动重试"
    }
    return IOSContinuedTaskFailure(
      reason: "\(schedulerErrorDomain):\(nsError.code)",
      message: "\(message)（\(schedulerErrorDomain)，代码 \(nsError.code)）"
    )
  }
}
