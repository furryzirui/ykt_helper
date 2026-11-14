#ifndef YKT_AUTOSTART_TEST
#include "app_autostart.h"
#include <flutter/standard_method_codec.h>
#endif
#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>

namespace {
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kApprovalKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";
constexpr wchar_t kValueName[] = L"ykt_helper";
constexpr wchar_t kPreferencesKey[] = L"Software\\furryzirui\\ykt_helper\\Autostart";

bool ReadFlag(const wchar_t* name) {
  DWORD value = 0;
  DWORD bytes = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER, kPreferencesKey, name,
      RRF_RT_REG_DWORD, nullptr, &value, &bytes) == ERROR_SUCCESS && value == 1;
}

bool WriteFlag(const wchar_t* name, bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kPreferencesKey, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  const DWORD value = enabled ? 1 : 0;
  const auto result = RegSetValueExW(key, name, 0, REG_DWORD,
      reinterpret_cast<const BYTE*>(&value), sizeof(value));
  RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

bool ReadCommand(const wchar_t* key, const wchar_t* name, std::wstring* command) {
  std::vector<wchar_t> value(32768);
  DWORD bytes = static_cast<DWORD>(value.size() * sizeof(wchar_t));
  if (RegGetValueW(HKEY_CURRENT_USER, key, name, RRF_RT_REG_SZ, nullptr,
      value.data(), &bytes) != ERROR_SUCCESS) return false;
  *command = value.data();
  return true;
}

bool WriteCommand(const wchar_t* path, const wchar_t* name,
                  const std::wstring& command) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  const auto result = RegSetValueExW(key, name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()),
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

std::wstring StartupCommand() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) return L"";
  return L"\"" + std::wstring(path.data(), length) + L"\" --background-auto-start";
}

bool HasPreparedStartupCommand() {
  if (!ReadFlag(L"prepared")) return false;
  const auto expected = StartupCommand();
  std::wstring command;
  return !expected.empty() && ReadCommand(kRunKey, kValueName, &command) && command == expected;
}

std::string StartupPermission() {
  BYTE approval[32]{};
  DWORD bytes = sizeof(approval);
  const LSTATUS approved = RegGetValueW(HKEY_CURRENT_USER, kApprovalKey, kValueName,
      RRF_RT_REG_BINARY, nullptr, approval, &bytes);
  if (approved == ERROR_FILE_NOT_FOUND || approved == ERROR_PATH_NOT_FOUND) {
    return HasPreparedStartupCommand() ? "granted" : "needsConfirmation";
  }
  if (approved != ERROR_SUCCESS || bytes < 12) return "needsConfirmation";
  // Windows also stores the default enabled state as exactly twelve zero bytes.
  // Electron recognizes this representation too. Other state-0 payloads and
  // unknown lengths remain unverified; only explicit denial blocks startup.
  // https://github.com/electron/electron/blob/v39.1.1/shell/browser/browser_win.cc#L223-L235
  if (bytes == 12) {
    bool default_enabled = true;
    for (DWORD index = 0; index < bytes; ++index) {
      if (approval[index] != 0) default_enabled = false;
    }
    if (default_enabled) return HasPreparedStartupCommand() ? "granted" : "needsConfirmation";
  }
  // StartupApproved is a Windows implementation detail. Preserve unknown status
  // for the permissions page, but the user's policy only blocks explicit denial.
  const DWORD state = static_cast<DWORD>(approval[0]) |
      (static_cast<DWORD>(approval[1]) << 8) |
      (static_cast<DWORD>(approval[2]) << 16) |
      (static_cast<DWORD>(approval[3]) << 24);
  if (state == 0x02 || state == 0x06) return HasPreparedStartupCommand() ? "granted" : "needsConfirmation";
  if (state == 0x03 || state == 0x07) return "denied";
  return "needsConfirmation";
}

bool PrepareStartup() {
  // Explicit permission-page consent registers a discoverable item. Registering
  // alone must never enable background work, including after a previous denial.
  if (!WriteFlag(L"eligible", false) || !WriteFlag(L"enabled", false)) return false;
  const auto command = StartupCommand();
  if (command.empty() || !WriteCommand(kRunKey, kValueName, command) ||
      !WriteCommand(kPreferencesKey, L"command", command)) return false;
  return WriteFlag(L"prepared", true);
}

bool ConfigureStartup(bool enabled, bool eligible) {
  // Stop first even when permission was revoked. In particular, logout must
  // clear eligibility without depending on the startup authorization state.
  if (!WriteFlag(L"eligible", false)) return false;
  if (enabled && eligible &&
      (!HasPreparedStartupCommand() || StartupPermission() == "denied")) return false;
  if (!WriteFlag(L"enabled", enabled)) return false;
  // Keep the registered item visible in StartupApps when the app switch is off.
  // The early main() guard checks these flags before creating any window/engine.
  return WriteFlag(L"eligible", enabled && eligible);
}

#ifndef YKT_AUTOSTART_TEST
bool ArgumentBool(const flutter::MethodCall<flutter::EncodableValue>& call,
                  const char* key) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!arguments) return false;
  const auto item = arguments->find(flutter::EncodableValue(key));
  return item != arguments->end() && std::holds_alternative<bool>(item->second) &&
      std::get<bool>(item->second);
}
#endif
}  // namespace

bool ShouldRunBackgroundAutostart() {
  return ReadFlag(L"enabled") && ReadFlag(L"eligible") &&
      HasPreparedStartupCommand() && StartupPermission() != "denied";
}

void RefreshPreparedStartupCommand() {
  if (!ReadFlag(L"prepared")) return;
  std::wstring registered, previous;
  // Repair a moved installation, but never recreate an externally removed item
  // or replace a command that no longer belongs to this app's saved registration.
  if (!ReadCommand(kRunKey, kValueName, &registered) ||
      !ReadCommand(kPreferencesKey, L"command", &previous) || registered != previous) return;
  const auto current = StartupCommand();
  if (current.empty() || current == registered) return;
  if (WriteCommand(kRunKey, kValueName, current)) {
    WriteCommand(kPreferencesKey, L"command", current);
  }
}

#ifndef YKT_AUTOSTART_TEST
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterAutostartChannel(flutter::FlutterEngine* engine, HWND window) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "ykt_helper/app_autostart",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window](const auto& call, auto result) {
    if (call.method_name() == "configure") {
      if (ConfigureStartup(ArgumentBool(call, "enabled"), ArgumentBool(call, "eligible"))) result->Success();
      else result->Error("autostart_save_failed", "无法保存开机启动设置");
    } else if (call.method_name() == "prepare") {
      if (PrepareStartup()) result->Success();
      else result->Error("autostart_prepare_failed", "无法添加 Windows 启动项");
    } else if (call.method_name() == "status") {
      const auto permission = StartupPermission();
      result->Success(flutter::EncodableMap{
          {flutter::EncodableValue("enabled"), flutter::EncodableValue(ShouldRunBackgroundAutostart())},
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
#endif
