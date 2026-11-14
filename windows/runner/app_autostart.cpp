#include "app_autostart.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>

namespace {
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kApprovalKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";
constexpr wchar_t kValueName[] = L"ykt_helper";

std::wstring StartupCommand() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) return L"";
  return L"\"" + std::wstring(path.data(), length) + L"\" --background-auto-start";
}

std::string StartupPermission() {
  const auto expected = StartupCommand();
  if (expected.empty()) return "needsConfirmation";
  std::vector<wchar_t> value(32768);
  DWORD bytes = static_cast<DWORD>(value.size() * sizeof(wchar_t));
  const LSTATUS queried = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kValueName,
      RRF_RT_REG_SZ, nullptr, value.data(), &bytes);
  if (queried == ERROR_FILE_NOT_FOUND || queried == ERROR_PATH_NOT_FOUND) return "denied";
  if (queried != ERROR_SUCCESS) return "needsConfirmation";
  if (std::wstring(value.data()) != expected) return "denied";
  BYTE approval[32]{};
  bytes = sizeof(approval);
  const LSTATUS approved = RegGetValueW(HKEY_CURRENT_USER, kApprovalKey, kValueName,
      RRF_RT_REG_BINARY, nullptr, approval, &bytes);
  if (approved == ERROR_FILE_NOT_FOUND || approved == ERROR_PATH_NOT_FOUND) return "granted";
  if (approved != ERROR_SUCCESS || bytes < 12) return "needsConfirmation";
  // StartupApproved is a Windows implementation detail. Unknown formats are
  // deliberately shown as requiring system confirmation, never as authorized.
  if (approval[0] == 0x02 || approval[0] == 0x06) return "granted";
  if (approval[0] == 0x03 || approval[0] == 0x07) return "denied";
  return "needsConfirmation";
}

bool ConfigureStartup(bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  LSTATUS result;
  if (enabled) {
    const auto command = StartupCommand();
    if (command.empty()) { RegCloseKey(key); return false; }
    result = RegSetValueExW(key, kValueName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = RegDeleteValueW(key, kValueName);
    if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  // Never override a user's explicit Task Manager / system StartupApps choice.
  return result == ERROR_SUCCESS;
}

bool ArgumentBool(const flutter::MethodCall<flutter::EncodableValue>& call,
                  const char* key) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!arguments) return false;
  const auto item = arguments->find(flutter::EncodableValue(key));
  return item != arguments->end() && std::holds_alternative<bool>(item->second) &&
      std::get<bool>(item->second);
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterAutostartChannel(flutter::FlutterEngine* engine, HWND window) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "ykt_helper/app_autostart",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window](const auto& call, auto result) {
    if (call.method_name() == "configure") {
      const bool enabled = ArgumentBool(call, "enabled") && ArgumentBool(call, "eligible");
      if (ConfigureStartup(enabled)) result->Success();
      else result->Error("autostart_save_failed", "无法保存开机启动设置");
    } else if (call.method_name() == "status") {
      const auto permission = StartupPermission();
      result->Success(flutter::EncodableMap{
          {flutter::EncodableValue("enabled"), flutter::EncodableValue(permission == "granted")},
          {flutter::EncodableValue("permission"), flutter::EncodableValue(permission)},
          {flutter::EncodableValue("suspended"), flutter::EncodableValue(false)}});
    } else if (call.method_name() == "isForeground") {
      result->Success(flutter::EncodableValue(IsWindowVisible(window) != FALSE));
    } else if (call.method_name() == "setSuspended") {
      result->Success();
    } else if (call.method_name() == "openSettings") {
      const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open",
          L"ms-settings:startupapps", nullptr, nullptr, SW_SHOWNORMAL));
      result->Success(flutter::EncodableValue(opened > 32));
    } else result->NotImplemented();
  });
  return channel;
}
