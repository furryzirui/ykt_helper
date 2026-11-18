import AVFoundation
import AVKit
import BackgroundTasks
import CoreLocation
import Flutter
import UIKit

/// Public iOS execution modes, selected explicitly in the foreground.
/// Owning one of these resources is not proof that Dart is executing: device
/// acceptance must also observe the application's real network heartbeat.
final class IOSBackgroundRuntime: NSObject, AVAudioPlayerDelegate,
  AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate,
  CLLocationManagerDelegate {
  private enum Mode: String {
    case silentAudio, pictureInPicture, continuedTask, location, native
  }

  private let channel: FlutterMethodChannel
  private var mode: Mode = .native
  private var deadlineEpochMs: Int64?
  private var deadlineUptime: TimeInterval?
  private var deadlineHasExpired = false
  private var enabled = false
  private var reason: String?
  private var message: String?
  private var deadlineTimer: Timer?
  private var player: AVAudioPlayer?
  private var audioSessionActive = false
  private var locationManager: CLLocationManager?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var pip: AVPictureInPictureController?
  private var pipLayer: AVSampleBufferDisplayLayer?
  private var pipView: UIView?
  private var pipFrameTimer: Timer?
  private var pipFrameCount = 0
  private var pipPossibleObserver: NSKeyValueObservation?
  private var pipStartupTimeout: DispatchWorkItem?
  private var pendingStart: FlutterResult?
  private var pipStartRequested = false
  private var continuedRuntime: AnyObject?
  private var continuedStartTimeout: DispatchWorkItem?
  private var notificationTokens: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ykt_helper/background_runtime", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      switch call.method {
      case "configure":
        guard self.configure(call.arguments, result: result) else { return }
        result(self.status())
      case "setEnabled":
        guard let arguments = call.arguments as? [String: Any],
              let requested = arguments["enabled"] as? Bool else {
          result(FlutterError(code: "invalid_runtime", message: "后台运行参数无效", details: nil))
          return
        }
        // Stopping must always work, even if saved configuration is invalid.
        if !requested {
          self.stop(reason: nil)
          result(true)
          return
        }
        guard self.configure(arguments, result: result) else { return }
        self.start(userInitiated: arguments["userInitiated"] as? Bool == true, result: result)
      case "status":
        self.expireIfNeeded()
        result(self.status())
      case "diagnostics":
        result(self.diagnostics())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.foreground() }
    observe(UIScene.didActivateNotification) { [weak self] in self?.foreground() }
    observe(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.enteredBackground() }
    observe(UIScene.didEnterBackgroundNotification) { [weak self] in self?.enteredBackground() }
    observe(UIApplication.significantTimeChangeNotification) { [weak self] in
      guard let self = self else { return }
      if !self.expireIfNeeded(), self.enabled || self.pendingStart != nil { self.scheduleDeadline() }
    }
    let center = NotificationCenter.default
    notificationTokens.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began,
            let self = self, self.player != nil || self.pip != nil else { return }
      self.stop(reason: "音频会话被系统中断，请返回应用重新开启", code: "interrupted")
    })
    observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] in
      guard let self = self, self.player != nil || self.pip != nil else { return }
      self.stop(reason: "系统媒体服务已重置，请重新开启", code: "interrupted")
    }
  }

  deinit {
    notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    deadlineTimer?.invalidate()
    pipFrameTimer?.invalidate()
    pipStartupTimeout?.cancel()
    pipPossibleObserver?.invalidate()
    continuedStartTimeout?.cancel()
    if #available(iOS 26.0, *) {
      (continuedRuntime as? IOSContinuedClassroomTask)?.finish(success: false)
    }
    player?.stop()
    locationManager?.stopUpdatingLocation()
    pip?.delegate = nil
    pip?.stopPictureInPicture()
    pipView?.removeFromSuperview()
    if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    if audioSessionActive {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func observe(_ name: Notification.Name, action: @escaping () -> Void) {
    notificationTokens.append(NotificationCenter.default.addObserver(
      forName: name, object: nil, queue: .main
    ) { _ in action() })
  }

  private var foregroundActive: Bool {
    UIApplication.shared.applicationState == .active &&
      UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
  }

  private func configure(_ value: Any?, result: FlutterResult) -> Bool {
    guard let arguments = value as? [String: Any] else {
      result(FlutterError(code: "invalid_runtime", message: "后台运行参数无效", details: nil))
      return false
    }
    var selectedMode = mode
    if let raw = arguments["mode"] as? String {
      guard let parsed = Mode(rawValue: raw) else {
        result(FlutterError(code: "invalid_mode", message: "无法识别此后台运行方式", details: nil))
        return false
      }
      selectedMode = parsed
    }
    var selectedDeadline = deadlineEpochMs
    if let value = arguments["deadlineEpochMs"] {
      if value is NSNull {
        selectedDeadline = nil
      } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, number.doubleValue > 0,
                number.doubleValue < Double(Int64.max),
                number.doubleValue.rounded(.towardZero) == number.doubleValue {
        selectedDeadline = number.int64Value
      } else {
        result(FlutterError(code: "invalid_deadline", message: "后台运行截止时间无效", details: nil))
        return false
      }
    }
    if selectedMode != mode && (enabled || pendingStart != nil) {
      stop(reason: "后台运行方式已更改，请重新开启", code: "configurationChanged")
    }
    mode = selectedMode
    if selectedDeadline != deadlineEpochMs {
      deadlineEpochMs = selectedDeadline
      deadlineHasExpired = false
      if let deadline = selectedDeadline {
        let remaining = max(0, Double(deadline) / 1000 - Date().timeIntervalSince1970)
        deadlineUptime = ProcessInfo.processInfo.systemUptime + remaining
      } else {
        deadlineUptime = nil
      }
      if reason == "deadline" { reason = nil; message = nil }
    }
    if #available(iOS 26.0, *), mode == .continuedTask,
       let task = continuedRuntime as? IOSContinuedClassroomTask, task.running {
      guard let deadline = deadlineEpochMs else {
        stop(reason: "限时课堂监控不能设置为永不关闭", code: "invalidDeadline")
        return true
      }
      task.updateDeadline(epochMs: deadline)
    }
    if !expireIfNeeded() && (enabled || pendingStart != nil) { scheduleDeadline() }
    return true
  }

  private func status() -> [String: Any] {
    var availableModes = [Mode.native.rawValue, Mode.silentAudio.rawValue,
                          Mode.pictureInPicture.rawValue, Mode.location.rawValue]
    if #available(iOS 26.0, *) { availableModes.append(Mode.continuedTask.rawValue) }
    var value: [String: Any] = [
      "enabled": enabled, "mode": mode.rawValue,
      "deadlineEpochMs": deadlineEpochMs.map { NSNumber(value: $0) as Any } ?? NSNull(),
      "availableModes": availableModes,
    ]
    if let reason = reason { value["reason"] = reason }
    if let message = message { value["message"] = message }
    return value
  }

  private func notify() { channel.invokeMethod("stateChanged", arguments: status()) }

  /// Read-only snapshots for opt-in test builds. No timer, media control, task
  /// submission or location reads are introduced by inspecting these values.
  private func diagnostics() -> [String: Any] {
    let state: String
    switch UIApplication.shared.applicationState {
    case .active: state = "active"
    case .inactive: state = "inactive"
    case .background: state = "background"
    @unknown default: state = "unknown"
    }
    var value: [String: Any] = [
      "enabled": enabled, "mode": mode.rawValue, "appState": state,
    ]
    if mode == .silentAudio {
      value["audioPlaying"] = player?.isPlaying == true
      value["audioTimeMs"] = Int64(max(0, player?.currentTime ?? 0) * 1000)
    } else if mode == .pictureInPicture {
      value["pipActive"] = pip?.isPictureInPictureActive == true
      value["pipFrameCount"] = pipFrameCount
    }
    return value
  }

  @discardableResult
  private func expireIfNeeded() -> Bool {
    guard let deadline = deadlineEpochMs else { return false }
    guard deadlineHasExpired ||
      Date().timeIntervalSince1970 * 1000 >= Double(deadline) ||
      deadlineUptime.map({ ProcessInfo.processInfo.systemUptime >= $0 }) == true else { return false }
    deadlineHasExpired = true
    if enabled || pendingStart != nil { stop(reason: "后台运行已到期", code: "deadline") }
    else { reason = "deadline"; message = "后台运行已到期" }
    return true
  }

  private func scheduleDeadline() {
    deadlineTimer?.invalidate()
    deadlineTimer = nil
    guard let deadline = deadlineEpochMs else { return }
    let wallRemaining = Double(deadline) / 1000 - Date().timeIntervalSince1970
    let monotonicRemaining = deadlineUptime.map { $0 - ProcessInfo.processInfo.systemUptime } ?? wallRemaining
    let remaining = min(wallRemaining, monotonicRemaining)
    guard remaining > 0 else { deadlineHasExpired = true; stop(reason: "后台运行已到期", code: "deadline"); return }
    deadlineTimer = Timer(timeInterval: min(remaining, 60), repeats: false) { [weak self] _ in
      guard let self = self else { return }
      // Re-check wall-clock time after clock adjustments; never extend the
      // configured absolute deadline on a repeated enable or app resume.
      if !self.expireIfNeeded() { self.scheduleDeadline() }
    }
    RunLoop.main.add(deadlineTimer!, forMode: .common)
  }

  private func start(userInitiated: Bool, result: @escaping FlutterResult) {
    if expireIfNeeded() {
      reason = "deadline"
      message = "后台运行截止时间已到，请重新设置时长"
      notify()
      result(false)
      return
    }
    if enabled { result(true); return }
    if pendingStart != nil {
      result(FlutterError(code: "runtime_busy", message: "后台运行正在启动，请稍候", details: nil))
      return
    }
    guard foregroundActive else {
      reason = "foregroundRequired"
      message = "请在应用前台手动开启后台运行"
      notify()
      result(false)
      return
    }
    reason = nil
    message = nil
    do {
      switch mode {
      case .silentAudio:
        try activateAudio()
        let audio = try AVAudioPlayer(data: Self.silentWave())
        audio.numberOfLoops = -1
        audio.delegate = self
        audio.prepareToPlay()
        guard audio.play() else { throw RuntimeFailure("静音音频启动失败") }
        player = audio
      case .pictureInPicture:
        pendingStart = result
        try startPictureInPicture()
        scheduleDeadline()
        return
      case .continuedTask:
        guard userInitiated else {
          throw RuntimeFailure("限时课堂监控需要每次在前台手动开启")
        }
        guard let deadline = deadlineEpochMs,
              Double(deadline) > Date().timeIntervalSince1970 * 1000 else {
          throw RuntimeFailure("限时课堂监控需要设置有限的运行时长")
        }
        guard #available(iOS 26.0, *) else {
          throw RuntimeFailure("限时课堂监控需要 iOS 26 或更新版本")
        }
        pendingStart = result
        try startContinuedTask(deadline: deadline)
        scheduleDeadline()
        return
      case .location:
        guard CLLocationManager.locationServicesEnabled() else {
          throw RuntimeFailure("系统定位服务未开启")
        }
        let manager = CLLocationManager()
        guard manager.authorizationStatus == .authorizedAlways else {
          throw RuntimeFailure("请先在应用权限中将定位设为始终允许")
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        locationManager = manager
        manager.startUpdatingLocation()
      case .native:
        // Foreground state is active now; request finite execution time only
        // when the scene actually enters the background.
        break
      }
      enabled = true
      scheduleDeadline()
      notify()
      result(true)
    } catch {
      let failure: IOSContinuedTaskFailure
      if let runtimeError = error as? RuntimeFailure {
        failure = IOSContinuedTaskFailure(reason: "startFailed", message: runtimeError.message)
      } else if mode == .continuedTask {
        failure = IOSContinuedTaskPolicy.failure(for: error)
      } else {
        failure = IOSContinuedTaskFailure(reason: "startFailed", message: "后台运行启动失败，请重试")
      }
      let wasPending = pendingStart != nil
      stop(reason: failure.message, code: failure.reason)
      if !wasPending { result(false) }
    }
  }

  private func activateAudio() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try session.setActive(true)
    audioSessionActive = true
  }

  private func stop(reason text: String?, code: String = "stopped") {
    enabled = false
    reason = code
    message = text
    deadlineTimer?.invalidate()
    deadlineTimer = nil
    pipStartupTimeout?.cancel()
    pipStartupTimeout = nil
    pipPossibleObserver?.invalidate()
    pipPossibleObserver = nil
    pipStartRequested = false
    continuedStartTimeout?.cancel()
    continuedStartTimeout = nil
    if #available(iOS 26.0, *) {
      (continuedRuntime as? IOSContinuedClassroomTask)?.finish(success: code == "deadline")
    }
    pipFrameTimer?.invalidate()
    pipFrameTimer = nil
    let previousPip = pip
    pip = nil
    previousPip?.delegate = nil
    previousPip?.stopPictureInPicture()
    pipLayer?.flushAndRemoveImage()
    pipLayer?.removeFromSuperlayer()
    pipLayer = nil
    pipView?.removeFromSuperview()
    pipView = nil
    player?.stop()
    player = nil
    locationManager?.stopUpdatingLocation()
    locationManager?.delegate = nil
    locationManager = nil
    finishNativeTask()
    if audioSessionActive {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionActive = false
    }
    let completion = pendingStart
    pendingStart = nil
    completion?(false)
    notify()
  }

  private func foreground() {
    if expireIfNeeded() { return }
    finishNativeTask()
    if enabled, mode == .silentAudio, player?.isPlaying != true {
      stop(reason: "静音音频已停止，请重新开启", code: "interrupted")
    } else if enabled, mode == .pictureInPicture, pip?.isPictureInPictureActive != true {
      stop(reason: "画中画已停止，请重新开启", code: "interrupted")
    } else if enabled, mode == .location,
              locationManager?.authorizationStatus != .authorizedAlways {
      stop(reason: "后台定位权限已变更，请重新授权", code: "permission")
    }
  }

  private func enteredBackground() {
    guard !expireIfNeeded(), enabled, mode == .native, backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "classroom-finish") { [weak self] in
      self?.stop(reason: "系统允许的短时后台运行已结束", code: "systemExpired")
    }
    if backgroundTask == .invalid { stop(reason: "系统未允许短时后台运行", code: "startFailed") }
  }

  private func finishNativeTask() {
    guard backgroundTask != .invalid else { return }
    let task = backgroundTask
    backgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(task)
  }

  @available(iOS 26.0, *)
  private func startContinuedTask(deadline: Int64) throws {
    let helper: IOSContinuedClassroomTask
    if let existing = continuedRuntime as? IOSContinuedClassroomTask {
      helper = existing
    } else {
      helper = IOSContinuedClassroomTask()
      continuedRuntime = helper
    }
    try helper.start(deadline: deadline, onStarted: { [weak self] in
      guard let self = self, self.mode == .continuedTask, self.pendingStart != nil,
            !self.expireIfNeeded() else { return }
      self.continuedStartTimeout?.cancel()
      self.continuedStartTimeout = nil
      self.enabled = true
      self.reason = nil
      self.message = nil
      self.scheduleDeadline()
      let completion = self.pendingStart
      self.pendingStart = nil
      self.notify()
      completion?(true)
    }, onExpired: { [weak self] in
      self?.stop(reason: "系统已取消限时课堂监控，后台运行已停止", code: "systemExpired")
    })
    guard pendingStart != nil else { return }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.pendingStart != nil, self.mode == .continuedTask else { return }
      self.stop(reason: "系统未启动限时课堂监控，请稍后手动重试", code: "startFailed")
    }
    continuedStartTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    if player === self.player { stop(reason: "静音音频播放失败，请重新开启", code: "interrupted") }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    if player === self.player { stop(reason: "静音音频已结束，请重新开启", code: "interrupted") }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if manager === locationManager, manager.authorizationStatus != .authorizedAlways {
      stop(reason: "后台定位权限已变更，请重新授权", code: "permission")
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Deliberately do not store, log or transmit device coordinates.
    expireIfNeeded()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard manager === locationManager else { return }
    if (error as? CLError)?.code == .locationUnknown { return }
    stop(reason: "后台定位已中断，请检查系统定位权限", code: "interrupted")
  }

  private func startPictureInPicture() throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw RuntimeFailure("此设备不支持画中画")
    }
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      let window = scene.windows.first(where: { $0.isKeyWindow }) else {
      throw RuntimeFailure("请返回应用前台后开启画中画")
    }
    try activateAudio()
    pipFrameCount = 0
    let preview = UIView(frame: CGRect(
      x: max(window.safeAreaInsets.left + 8, window.bounds.width - window.safeAreaInsets.right - 168),
      y: window.safeAreaInsets.top + 64, width: 160, height: 90
    ))
    preview.backgroundColor = .black
    preview.layer.cornerRadius = 10
    preview.clipsToBounds = true
    preview.isUserInteractionEnabled = false
    preview.accessibilityLabel = "后台画中画时钟"
    let displayLayer = AVSampleBufferDisplayLayer()
    displayLayer.frame = preview.bounds
    displayLayer.videoGravity = .resizeAspect
    preview.layer.addSublayer(displayLayer)
    window.addSubview(preview)
    pipView = preview
    pipLayer = displayLayer
    var timebase: CMTimebase?
    guard CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase
    ) == noErr, let clock = timebase else { throw RuntimeFailure("画中画时钟初始化失败") }
    CMTimebaseSetTime(clock, time: CMClockGetTime(CMClockGetHostTimeClock()))
    CMTimebaseSetRate(clock, rate: 1)
    displayLayer.controlTimebase = clock
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer, playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    controller.requiresLinearPlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    pip = controller
    try renderPictureFrame()
    pipFrameTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      guard let self = self, !self.expireIfNeeded() else { return }
      do { try self.renderPictureFrame() }
      catch { self.stop(reason: "画中画画面生成失败，请重新开启", code: "interrupted") }
    }
    RunLoop.main.add(pipFrameTimer!, forMode: .common)
    pipPossibleObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      [weak self] controller, _ in
      DispatchQueue.main.async {
        guard let self = self, controller === self.pip, self.pendingStart != nil,
              controller.isPictureInPicturePossible, !controller.isPictureInPictureActive,
              !self.pipStartRequested,
              self.foregroundActive, !self.expireIfNeeded() else { return }
        self.pipStartRequested = true
        controller.startPictureInPicture()
      }
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.pendingStart != nil else { return }
      self.stop(reason: "画中画未能启动，请检查系统画中画设置后重试", code: "startFailed")
    }
    pipStartupTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
  }

  private func renderPictureFrame() throws {
    guard let layer = pipLayer else { return }
    if layer.status == .failed { layer.flush() }
    guard layer.isReadyForMoreMediaData else { return }
    let width = 480, height = 270
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    guard CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
      attributes as CFDictionary, &pixelBuffer
    ) == kCVReturnSuccess, let buffer = pixelBuffer else {
      throw RuntimeFailure("画中画像素缓冲区创建失败")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else { throw RuntimeFailure("画中画绘图初始化失败") }
    context.setFillColor(UIColor(red: 0.08, green: 0.1, blue: 0.16, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    UIGraphicsPushContext(context)
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let time = formatter.string(from: Date()) as NSString
    let attributesText: [NSAttributedString.Key: Any] = [
      .font: UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .medium),
      .foregroundColor: UIColor.white,
    ]
    let size = time.size(withAttributes: attributesText)
    time.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2),
              withAttributes: attributesText)
    UIGraphicsPopContext()
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format
    ) == noErr, let description = format else { throw RuntimeFailure("画中画视频格式创建失败") }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 1),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description,
      sampleTiming: &timing, sampleBufferOut: &sample
    ) == noErr, let frame = sample else { throw RuntimeFailure("画中画视频帧创建失败") }
    layer.enqueue(frame)
    pipFrameCount += 1
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    guard controller === pip, pendingStart != nil else { return }
    guard !expireIfNeeded() else { return }
    pipStartupTimeout?.cancel()
    pipStartupTimeout = nil
    enabled = true
    reason = nil
    message = nil
    scheduleDeadline()
    let completion = pendingStart
    pendingStart = nil
    notify()
    completion?(true)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
                                failedToStartPictureInPictureWithError error: Error) {
    if controller === pip { stop(reason: "画中画启动失败，请检查系统设置后重试", code: "startFailed") }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    if controller === pip { stop(reason: "画中画已关闭，后台运行已停止", code: "interrupted") }
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    completionHandler(foregroundActive)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    if controller === pip, !playing { stop(reason: "画中画已暂停，后台运行已停止", code: "interrupted") }
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    controller !== pip || (!enabled && pendingStart == nil)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    completionHandler()
  }

  private struct RuntimeFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private static func silentWave() -> Data {
    let samples: UInt32 = 8000
    let dataSize = samples * 2
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func word<T: FixedWidthInteger>(_ value: T) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    text("RIFF"); word(UInt32(36) + dataSize); text("WAVEfmt ")
    word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(samples)
    word(samples * 2); word(UInt16(2)); word(UInt16(16)); text("data"); word(dataSize)
    data.append(Data(count: Int(dataSize)))
    return data
  }
}

/// A user-started, finite monitoring session. The displayed progress is elapsed
/// session time, never an invented amount of AI/CPU work or submitted answers.
@available(iOS 26.0, *)
private final class IOSContinuedClassroomTask {
  private var sessionIdentifier: String?
  private var submitted = false
  private var task: BGContinuedProcessingTask?
  private var timer: Timer?
  private var startEpochMs: Int64 = 0
  private var startUptime: TimeInterval = 0
  private var deadlineEpochMs: Int64 = 0
  private var onStarted: (() -> Void)?
  private var onExpired: (() -> Void)?
  var running: Bool { task != nil }

  func start(deadline: Int64, onStarted: @escaping () -> Void,
             onExpired: @escaping () -> Void) throws {
    guard !submitted, task == nil else {
      throw IOSContinuedTaskPolicy.busy
    }
    // Signing tools may rewrite CFBundleIdentifier without updating this
    // compiled plist array. Reject that mismatch before asking the scheduler;
    // reusing the old prefix would violate Apple's submitting-Bundle-ID rule.
    let identifierPrefix = try IOSContinuedTaskPolicy.identifierPrefix(
      bundleIdentifier: Bundle.main.bundleIdentifier,
      permittedIdentifiers: Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
    )
    let identifier = identifierPrefix + UUID().uuidString
    // iOS 26 explicitly permits dynamically registering continued-processing
    // handlers. The exact request ID lives under the Info.plist wildcard prefix.
    // A distinct ID is necessary to reject late launches from a cancelled start.
    // https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/init(identifier:title:subtitle:)
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
      [weak self] incoming in
      guard let self = self, let continued = incoming as? BGContinuedProcessingTask else {
        incoming.setTaskCompleted(success: false)
        return
      }
      guard self.submitted, self.sessionIdentifier == identifier,
            incoming.identifier == identifier, self.task == nil else {
        incoming.setTaskCompleted(success: false)
        return
      }
      self.task = continued
      continued.expirationHandler = { [weak self, weak continued] in
        DispatchQueue.main.async {
          guard let self = self, let continued = continued,
                self.sessionIdentifier == identifier, self.task === continued else { return }
          let callback = self.onExpired
          self.finish(success: false)
          callback?()
        }
      }
      self.updateProgress()
      self.timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
        guard let self = self, self.sessionIdentifier == identifier else { return }
        self.updateProgress()
      }
      RunLoop.main.add(self.timer!, forMode: .common)
      let callback = self.onStarted
      self.onStarted = nil
      callback?()
    }
    guard registered else { throw IOSContinuedTaskPolicy.registrationRejected }
    self.onStarted = onStarted
    self.onExpired = onExpired
    sessionIdentifier = identifier
    startEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
    startUptime = ProcessInfo.processInfo.systemUptime
    deadlineEpochMs = deadline
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: "后台运行中", subtitle: subtitle(elapsedSeconds: 0)
    )
    request.strategy = .fail
    // Empty/default resources permit CPU and networking; no background GPU
    // entitlement is requested by this monitoring implementation.
    submitted = true
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      submitted = false
      sessionIdentifier = nil
      self.onStarted = nil
      self.onExpired = nil
      throw IOSContinuedTaskPolicy.failure(for: error)
    }
  }

  func updateDeadline(epochMs: Int64) {
    deadlineEpochMs = epochMs
    updateProgress()
  }

  private func subtitle(elapsedSeconds: Int64) -> String {
    let totalMinutes = max(1, Int64(ceil(Double(max(1, deadlineEpochMs - startEpochMs)) / 60_000)))
    return "已运行 \(max(0, elapsedSeconds) / 60) 分钟 / \(totalMinutes) 分钟"
  }

  private func updateProgress() {
    guard let task = task else { return }
    let totalSeconds = max(1, Int64(ceil(Double(deadlineEpochMs - startEpochMs) / 1000)))
    let elapsedSeconds = max(0, Int64(ProcessInfo.processInfo.systemUptime - startUptime))
    task.progress.totalUnitCount = totalSeconds
    task.progress.completedUnitCount = min(totalSeconds, elapsedSeconds)
    task.updateTitle("后台运行中", subtitle: subtitle(elapsedSeconds: elapsedSeconds))
  }

  func finish(success: Bool) {
    timer?.invalidate()
    timer = nil
    let previous = task
    task = nil
    let previousIdentifier = sessionIdentifier
    sessionIdentifier = nil
    let wasSubmitted = submitted
    submitted = false
    previous?.expirationHandler = nil
    if success, let previous = previous {
      previous.progress.completedUnitCount = previous.progress.totalUnitCount
    }
    previous?.setTaskCompleted(success: success)
    if wasSubmitted, previous == nil, let identifier = previousIdentifier {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
    onStarted = nil
    onExpired = nil
  }
}

/// Always authorization can be deferred by iOS. Requests are bounded and report
/// actual authorization rather than waiting forever for a second system sheet.
final class IOSLocationPermissions: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var completion: ((Any?) -> Void)?
  private var timeout: DispatchWorkItem?
  private var upgradeRequested = false
  private var activeObserver: NSObjectProtocol?

  override init() {
    super.init()
    manager.delegate = self
    activeObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self?.finishUpgradeIfNoSystemSheet()
      }
    }
  }

  deinit {
    if let observer = activeObserver { NotificationCenter.default.removeObserver(observer) }
    timeout?.cancel()
  }

  var state: String {
    guard CLLocationManager.locationServicesEnabled() else { return "denied" }
    switch manager.authorizationStatus {
    case .authorizedAlways: return "granted"
    case .notDetermined, .authorizedWhenInUse: return "needsConfirmation"
    case .denied, .restricted: return "denied"
    @unknown default: return "needsConfirmation"
    }
  }

  func request(completion: @escaping (Any?) -> Void) {
    guard UIApplication.shared.applicationState == .active else {
      completion(FlutterError(code: "location_foreground", message: "请在应用前台申请定位权限", details: nil))
      return
    }
    guard self.completion == nil else {
      completion(FlutterError(code: "permission_busy", message: "定位权限申请尚未完成", details: nil))
      return
    }
    guard CLLocationManager.locationServicesEnabled() else {
      completion(FlutterError(code: "location_disabled", message: "请先开启系统定位服务", details: nil))
      return
    }
    switch manager.authorizationStatus {
    case .authorizedAlways: completion(true)
    case .denied:
      completion(FlutterError(code: "location_denied", message: "定位权限已被拒绝，请在系统设置中改为始终允许", details: nil))
    case .restricted:
      completion(FlutterError(code: "location_restricted", message: "系统限制了此设备的定位授权", details: nil))
    case .notDetermined, .authorizedWhenInUse:
      self.completion = completion
      upgradeRequested = manager.authorizationStatus == .authorizedWhenInUse
      let work = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        self.finish(self.manager.authorizationStatus == .authorizedAlways ? true : FlutterError(
          code: "location_needs_always", message: "请在系统设置中将定位改为始终允许后再开启", details: nil
        ))
      }
      timeout = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
      if upgradeRequested {
        manager.requestAlwaysAuthorization()
        // iOS can decline to present an upgrade sheet without a delegate call.
        // Give it time to present, then finish with the real status either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
          self?.finishUpgradeIfNoSystemSheet()
        }
      } else {
        manager.requestWhenInUseAuthorization()
      }
    @unknown default:
      completion(FlutterError(code: "location_unknown", message: "无法读取定位权限，请在系统设置中确认", details: nil))
    }
  }

  private func finishUpgradeIfNoSystemSheet() {
    guard completion != nil, upgradeRequested,
          UIApplication.shared.applicationState == .active else { return }
    if manager.authorizationStatus == .authorizedAlways { finish(true) }
    else {
      finish(FlutterError(code: "location_needs_always", message: "请在系统设置中将定位改为始终允许后再开启", details: nil))
    }
  }

  private func finish(_ value: Any?) {
    let callback = completion
    completion = nil
    timeout?.cancel()
    timeout = nil
    callback?(value)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard completion != nil else { return }
    switch manager.authorizationStatus {
    case .authorizedAlways: finish(true)
    case .denied:
      finish(FlutterError(code: "location_denied", message: "定位权限未获允许，可在系统设置中修改", details: nil))
    case .restricted:
      finish(FlutterError(code: "location_restricted", message: "系统限制了此设备的定位授权", details: nil))
    case .authorizedWhenInUse:
      if !upgradeRequested {
        upgradeRequested = true
        manager.requestAlwaysAuthorization()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
          self?.finishUpgradeIfNoSystemSheet()
        }
      } else {
        finishUpgradeIfNoSystemSheet()
      }
    case .notDetermined: break
    @unknown default:
      finish(FlutterError(code: "location_unknown", message: "无法读取定位权限，请在系统设置中确认", details: nil))
    }
  }
}
