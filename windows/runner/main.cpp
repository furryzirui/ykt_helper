#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>
#include <sddl.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
std::wstring UserInstanceName() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return L"";
  DWORD bytes = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
  std::vector<BYTE> data(bytes);
  if (bytes == 0 || !GetTokenInformation(token, TokenUser, data.data(), bytes, &bytes)) {
    CloseHandle(token);
    return L"";
  }
  CloseHandle(token);
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<const TOKEN_USER*>(data.data())->User.Sid, &sid)) return L"";
  std::wstring name = L"Local\\com.furryzirui.ykt_helper." + std::wstring(sid) + L".instance";
  LocalFree(sid);
  return name;
}
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool background_start = std::find(command_line_arguments.begin(),
      command_line_arguments.end(), "--background-auto-start") != command_line_arguments.end();

  // A visible startup item is only authorization. Saved app settings must also
  // permit background work; an off switch never creates a hidden Flutter app.
  if (background_start && !ShouldRunBackgroundAutostart()) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }
  if (!background_start) RefreshPreparedStartupCommand();

  // All entry paths share the same automation owner. A normal launch restores
  // the already running background window instead of sending answers twice.
  const auto instance_name = UserInstanceName();
  if (instance_name.empty()) { ::CoUninitialize(); return EXIT_FAILURE; }
  HANDLE singleton = CreateMutexW(nullptr, FALSE, instance_name.c_str());
  if (singleton == nullptr) { ::CoUninitialize(); return EXIT_FAILURE; }
  if (singleton != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    if (!background_start) {
      EnumWindows([](HWND hwnd, LPARAM parameter) -> BOOL {
        const auto* property = reinterpret_cast<const std::wstring*>(parameter);
        if (GetPropW(hwnd, property->c_str()) != nullptr) {
          DWORD process = 0;
          GetWindowThreadProcessId(hwnd, &process);
          AllowSetForegroundWindow(process);
          PostMessageW(hwnd, WM_APP + 41, 0, 0);
          return FALSE;
        }
        return TRUE;
      }, reinterpret_cast<LPARAM>(&instance_name));
    }
    CloseHandle(singleton);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, background_start, instance_name);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ykt_helper", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (singleton != nullptr) CloseHandle(singleton);
  return EXIT_SUCCESS;
}
