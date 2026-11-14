import Flutter
import UIKit
import AVFoundation
import Photos
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var permissionPending = false
  private var galleryPending = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let integrity = FlutterMethodChannel(
      name: "ykt_helper/integrity", binaryMessenger: messenger
    )
    integrity.setMethodCallHandler { call, result in
      switch call.method {
      case "applicationRoot":
        result(Bundle.main.bundlePath)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let permissions = FlutterMethodChannel(
      name: "ykt_helper/app_permissions", binaryMessenger: messenger
    )
    permissions.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "permission_unavailable", message: "应用权限服务不可用", details: nil))
        return
      }
      switch call.method {
      case "check":
        self.checkPermissions(result: result)
      case "request", "openSettings":
        guard let arguments = call.arguments as? [String: Any],
              let permission = arguments["permission"] as? String,
              ["camera", "notifications", "photos", "battery"].contains(permission) else {
          result(FlutterError(code: "invalid_permission", message: "无法识别此权限设置", details: nil))
          return
        }
        if permission == "battery" {
          result(FlutterError(code: "unsupported_permission", message: "iOS 不提供此电池优化开关", details: nil))
        } else if call.method == "openSettings" {
          self.openApplicationSettings(result: result)
        } else {
          self.requestPermission(permission, result: result)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let gallery = FlutterMethodChannel(name: "ykt_helper/gallery", binaryMessenger: messenger)
    gallery.setMethodCallHandler { [weak self] call, result in
      guard call.method == "saveImage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else {
        result(FlutterError(code: "gallery_unavailable", message: "相册服务不可用", details: nil))
        return
      }
      self.saveImage(call.arguments, result: result)
    }
  }

  private func cameraState() -> String {
    AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? "granted" : "denied"
  }

  private func photosState() -> String {
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    return status == .authorized || status == .limited ? "granted" : "denied"
  }

  private func notificationsState(_ settings: UNNotificationSettings) -> String {
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return "granted"
    default:
      return "denied"
    }
  }

  // Reading status must never request a system permission dialog.
  private func checkPermissions(result: @escaping FlutterResult) {
    let camera = cameraState()
    let photos = photosState()
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      guard let self = self else { return }
      let notifications = self.notificationsState(settings)
      DispatchQueue.main.async {
        result([
          "camera": camera, "photos": photos,
          "notifications": notifications, "battery": "unsupported"
        ])
      }
    }
  }

  private func openApplicationSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString),
          UIApplication.shared.canOpenURL(url) else {
      result(FlutterError(code: "settings_unavailable", message: "无法打开本应用设置", details: nil))
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  private func finishPermission(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async { [weak self] in
      self?.permissionPending = false
      result(value)
    }
  }

  private func openDeniedPermissionSettings(result: @escaping FlutterResult) {
    // The Flutter explanation already described this fallback and was confirmed.
    openApplicationSettings { [weak self] value in
      if let error = value as? FlutterError {
        self?.finishPermission(result, value: error)
      } else {
        self?.finishPermission(result, value: false)
      }
    }
  }

  private func requestPermission(_ permission: String, result: @escaping FlutterResult) {
    guard !permissionPending else {
      result(FlutterError(code: "permission_busy", message: "另一项权限申请尚未完成", details: nil))
      return
    }
    permissionPending = true
    switch permission {
    case "camera":
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        finishPermission(result, value: true)
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
          self?.finishPermission(result, value: granted)
        }
      default:
        openDeniedPermissionSettings(result: result)
      }
    case "photos":
      switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
      case .authorized, .limited:
        finishPermission(result, value: true)
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
          self?.finishPermission(result, value: status == .authorized || status == .limited)
        }
      default:
        openDeniedPermissionSettings(result: result)
      }
    case "notifications":
      let center = UNUserNotificationCenter.current()
      center.getNotificationSettings { [weak self] settings in
        guard let self = self else { return }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
          self.finishPermission(result, value: true)
        case .notDetermined:
          center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if error != nil {
              self.finishPermission(result, value: FlutterError(
                code: "permission_unavailable", message: "无法申请通知权限，请重试", details: nil
              ))
            } else {
              self.finishPermission(result, value: granted)
            }
          }
        default:
          DispatchQueue.main.async { self.openDeniedPermissionSettings(result: result) }
        }
      }
    default:
      finishPermission(result, value: FlutterError(
        code: "invalid_permission", message: "无法识别此权限设置", details: nil
      ))
    }
  }

  private func saveImage(_ arguments: Any?, result: @escaping FlutterResult) {
    guard !galleryPending else {
      result(FlutterError(code: "gallery_busy", message: "另一张图片仍在保存，请稍后重试", details: nil))
      return
    }
    guard photosState() == "granted" else {
      // The calling UI must explain and request authorization before writing.
      result(FlutterError(code: "photos_denied", message: "请先允许保存到相册", details: nil))
      return
    }
    guard let value = arguments as? [String: Any],
          let bytes = value["bytes"] as? FlutterStandardTypedData,
          let name = value["name"] as? String, !name.isEmpty,
          let mime = value["mimeType"] as? String,
          ["image/png", "image/jpeg"].contains(mime),
          !bytes.data.isEmpty, UIImage(data: bytes.data) != nil else {
      result(FlutterError(code: "invalid_image", message: "课件图片数据无效", details: nil))
      return
    }
    let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "_")
    galleryPending = true
    PHPhotoLibrary.shared().performChanges({
      let asset = PHAssetCreationRequest.forAsset()
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = String(safeName.prefix(180))
      options.uniformTypeIdentifier = mime == "image/png" ? "public.png" : "public.jpeg"
      asset.addResource(with: .photo, data: bytes.data, options: options)
    }) { [weak self] success, _ in
      DispatchQueue.main.async {
        self?.galleryPending = false
        if success {
          result(true)
        } else {
          result(FlutterError(code: "gallery_failed", message: "图片保存到系统相册失败，请检查权限和存储空间", details: nil))
        }
      }
    }
  }
}
