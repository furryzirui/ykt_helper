#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kShowExisting = WM_APP + 41;
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT kTrayShow = 1;
constexpr UINT kTrayExit = 2;
constexpr UINT kTimedExit = WM_APP + 43;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool background_start,
                             const std::wstring& instance_property)
    : project_(project), background_start_(background_start),
      instance_property_(instance_property) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  startup_channel_ = RegisterAutostartChannel(flutter_controller_->engine(), GetHandle());
  runtime_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ykt_helper/background_runtime",
      &flutter::StandardMethodCodec::GetInstance());
  runtime_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "exitApplication") {
          if (IsWindowVisible(GetHandle()) && !IsIconic(GetHandle())) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          // Reply before releasing the engine/window, then use the same clean
          // shutdown path as the tray Exit command.
          const bool queued = PostMessageW(GetHandle(), kTimedExit, 0, 0) != FALSE;
          result->Success(flutter::EncodableValue(queued));
        } else {
          result->NotImplemented();
        }
      });
  SetPropW(GetHandle(), instance_property_.c_str(), reinterpret_cast<HANDLE>(1));
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!background_start_) this->Show();
    else UpdateTrayIcon(true);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UpdateTrayIcon(false);
  RemovePropW(GetHandle(), instance_property_.c_str());
  startup_channel_ = nullptr;
  runtime_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowExisting() {
  background_start_ = false;
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
  UpdateTrayIcon(false);
  if (startup_channel_) startup_channel_->InvokeMethod("foreground", nullptr);
}

void FlutterWindow::UpdateTrayIcon(bool add) {
  if (!add && !tray_icon_) return;
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"ykt_helper");
  if (Shell_NotifyIconW(add ? NIM_ADD : NIM_DELETE, &icon)) tray_icon_ = add;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case kTimedExit:
      if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) Destroy();
      return 0;
    case kShowExisting:
      ShowExisting();
      return 0;
    case kTrayMessage:
      if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) ShowExisting();
      else if (lparam == WM_RBUTTONUP) {
        POINT point{};
        GetCursorPos(&point);
        HMENU menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING, kTrayShow, L"打开 ykt_helper");
        AppendMenuW(menu, MF_STRING, kTrayExit, L"退出");
        SetForegroundWindow(hwnd);
        const UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
            point.x, point.y, 0, hwnd, nullptr);
        DestroyMenu(menu);
        if (selected == kTrayShow) ShowExisting();
        else if (selected == kTrayExit) Destroy();
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
