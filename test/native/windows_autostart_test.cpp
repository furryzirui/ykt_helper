// Exercise the production policy against an isolated, process-local HKCU.
// No startup entry is added to the real user's Run / StartupApproved keys.
#define YKT_AUTOSTART_TEST
#include "../../windows/runner/app_autostart.cpp"

#include <iostream>
#include <stdexcept>

namespace {
int checks = 0;
void Check(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
  ++checks;
}

class RegistrySandbox {
 public:
  RegistrySandbox() {
    path_ = L"Software\\ykt_helper_autostart_test_" +
        std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
    Check(RegCreateKeyExW(HKEY_CURRENT_USER, path_.c_str(), 0, nullptr,
        REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, nullptr, &key_, nullptr) == ERROR_SUCCESS,
        "create isolated registry root");
    Check(RegOverridePredefKey(HKEY_CURRENT_USER, key_) == ERROR_SUCCESS,
        "redirect process-local HKCU");
  }
  ~RegistrySandbox() {
    RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
    RegCloseKey(key_);
    RegDeleteTreeW(HKEY_CURRENT_USER, path_.c_str());
  }
 private:
  HKEY key_ = nullptr;
  std::wstring path_;
};

void Approval(DWORD value, DWORD length = 12) {
  HKEY key = nullptr;
  Check(RegCreateKeyExW(HKEY_CURRENT_USER, kApprovalKey, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS, "create approval key");
  DWORD data[3] = {value, 0, 0};
  const auto result = RegSetValueExW(key, kValueName, 0, REG_BINARY,
      reinterpret_cast<const BYTE*>(data), length);
  RegCloseKey(key);
  Check(result == ERROR_SUCCESS, "write isolated approval state");
}
}  // namespace

int main() {
  try {
    RegistrySandbox sandbox;
    std::wstring command;
    Check(StartupPermission() == "denied", "fresh install is unauthorized");
    Check(!ConfigureStartup(true, true), "cannot enable before authorization");
    Check(!ReadCommand(kRunKey, kValueName, &command), "configure must not register startup");
    Check(!ShouldRunBackgroundAutostart(), "no background app before authorization");

    Check(PrepareStartup(), "explicit consent prepares startup item");
    Check(ReadCommand(kRunKey, kValueName, &command) && command == StartupCommand(),
        "startup item is discoverable with the correct quoted command");
    Check(StartupPermission() == "granted", "registered Run item defaults to enabled in Windows");
    Check(!ShouldRunBackgroundAutostart(), "authorization alone must not start work");
    Check(ConfigureStartup(true, true) && ShouldRunBackgroundAutostart(), "authorized enable works");
    Check(ConfigureStartup(false, false) && !ShouldRunBackgroundAutostart(), "off prevents launch");
    Check(ReadCommand(kRunKey, kValueName, &command), "off keeps permission item discoverable");

    Approval(3);
    Check(StartupPermission() == "denied", "system-disabled Run item is denied");
    Check(!ConfigureStartup(true, true), "native policy refuses revoked authorization");
    Check(!ShouldRunBackgroundAutostart(), "revocation prevents launch");
    Check(PrepareStartup() && StartupPermission() == "denied", "prepare never overrides system denial");
    Check(ConfigureStartup(true, false), "logout/ineligible stop works while permission denied");
    Check(!ReadFlag(L"eligible"), "safe stop clears eligibility durably");

    Approval(0x102);
    Check(StartupPermission() == "needsConfirmation", "unknown DWORD is not treated as enabled");
    Check(!ConfigureStartup(true, true), "unknown approval cannot enable startup");
    Approval(2, 4);
    Check(StartupPermission() == "needsConfirmation", "truncated approval is unverified");
    Approval(6);
    Check(StartupPermission() == "granted", "known enabled status is accepted");
    Check(ConfigureStartup(true, true) && ShouldRunBackgroundAutostart(), "enable after real grant");
    Approval(7);
    Check(!ShouldRunBackgroundAutostart(), "revocation also stops already-saved startup");
    Check(ConfigureStartup(false, false), "can clear saved preference after revocation");
    Approval(2);
    Check(!ShouldRunBackgroundAutostart(), "regrant alone does not undo user's off switch");

    Check(WriteCommand(kRunKey, kValueName, L"old-install --background-auto-start") &&
        WriteCommand(kPreferencesKey, L"command", L"old-install --background-auto-start"), "simulate move");
    RefreshPreparedStartupCommand();
    Check(ReadCommand(kRunKey, kValueName, &command) && command == StartupCommand(), "repair owned moved path");
    Check(WriteCommand(kRunKey, kValueName, L"unrelated-command"), "simulate replaced item");
    RefreshPreparedStartupCommand();
    Check(ReadCommand(kRunKey, kValueName, &command) && command == L"unrelated-command", "do not replace unknown command");
    Check(StartupPermission() == "denied", "wrong command is unauthorized");
    Check(RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kValueName) == ERROR_SUCCESS, "remove registered item");
    RefreshPreparedStartupCommand();
    Check(!ReadCommand(kRunKey, kValueName, &command), "do not recreate externally removed startup item");
    Check(!ShouldRunBackgroundAutostart(), "missing Run item cannot launch");

    std::cout << "Windows autostart: " << checks << " isolated registry checks passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
