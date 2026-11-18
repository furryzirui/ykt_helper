import Foundation

func expectFailure(_ identifier: String?, _ permitted: [String]?, reason: String) {
  do {
    _ = try IOSContinuedTaskPolicy.identifierPrefix(bundleIdentifier: identifier, permittedIdentifiers: permitted)
    fatalError("Accepted a configuration that cannot register the actual runtime identifier")
  } catch let error as IOSContinuedTaskFailure {
    precondition(error.reason == reason)
  } catch { fatalError("Unexpected configuration error") }
}

let original = "com.furryzirui.ykt-helper"
let replacement = "com.example.sideloaded"
let originalWildcard = original + ".classroomMonitoring.*"
let replacementWildcard = replacement + ".classroomMonitoring.*"
let originalPrefix = try IOSContinuedTaskPolicy.identifierPrefix(
  bundleIdentifier: original, permittedIdentifiers: [originalWildcard]
)
precondition(originalPrefix == original + ".classroomMonitoring.")
expectFailure(replacement, [originalWildcard], reason: "continuedIdentifierMismatch")
expectFailure(replacement, nil, reason: "continuedIdentifierMismatch")
expectFailure(replacement, [replacement + ".*"], reason: "continuedIdentifierMismatch")
let replacementPrefix = try IOSContinuedTaskPolicy.identifierPrefix(
  bundleIdentifier: replacement, permittedIdentifiers: ["com.other.task", replacementWildcard]
)
precondition(replacementPrefix == replacement + ".classroomMonitoring.")
for invalid in [nil, "", "com.bad_id", "com..empty", "$(PRODUCT_BUNDLE_IDENTIFIER)", "com.example\nsecret"] as [String?] {
  expectFailure(invalid, [originalWildcard], reason: "continuedInvalidBundleIdentifier")
}
let secret = "PRIVATE_SECRET_DO_NOT_PRINT"
for code in [1, 2, 3, 4, 567] {
  let failure = IOSContinuedTaskPolicy.failure(for: NSError(
    domain: "BGTaskSchedulerErrorDomain", code: code,
    userInfo: [NSLocalizedDescriptionKey: secret, "path": secret]
  ))
  precondition(failure.reason == "BGTaskSchedulerErrorDomain:\(code)")
  precondition(failure.message.contains("BGTaskSchedulerErrorDomain"))
  precondition(failure.message.contains("代码 \(code)"))
  precondition(!failure.message.contains(secret))
}
let foreignFailure = IOSContinuedTaskPolicy.failure(for: NSError(
  domain: secret, code: 66, userInfo: [NSLocalizedDescriptionKey: secret]
))
precondition(foreignFailure.reason == "continuedSubmitFailed")
precondition(!foreignFailure.message.contains(secret))
for failure in [IOSContinuedTaskPolicy.busy, IOSContinuedTaskPolicy.registrationRejected] {
  let preserved = IOSContinuedTaskPolicy.failure(for: failure)
  precondition(preserved.reason == failure.reason && preserved.message == failure.message)
}
print("Continued task signing and error policy tests passed")
