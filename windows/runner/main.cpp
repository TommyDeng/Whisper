#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
constexpr const wchar_t kSingleInstanceMutex[] =
    L"Local\\org.tommydeng.whisper.single";

// 已经有一个进程在跑：把那扇窗口请到前台，然后自己退出。
bool FocusExistingInstance() {
  HWND hwnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"\u8033\u8bed");
  if (hwnd == nullptr) {
    return false;
  }
  if (::IsIconic(hwnd) || !::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  }
  ::ShowWindow(hwnd, SW_SHOW);
  ::SetForegroundWindow(hwnd);
  return true;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    FocusExistingInstance();
    ::CloseHandle(mutex);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\u8033\u8bed", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
