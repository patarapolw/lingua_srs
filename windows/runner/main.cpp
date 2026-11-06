#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Only one copy of the app runs per Windows session. Every copy would read
// and write the same data folder (%APPDATA%\cc.polv\lingua.srs) and sync it
// on its own, so a second one could overwrite the first one's changes (#104).
constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\cc.polv.lingua.srs.single-instance";

// Brings the window of the copy that is already running to the front. If it
// is still starting and has no window yet, there is nothing to show.
void ShowRunningInstance() {
  HWND window = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"lingua_srs");
  if (window == nullptr) {
    return;
  }
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Held until this process exits; Windows closes it then.
  HANDLE instance_mutex =
      ::CreateMutex(nullptr, FALSE, kSingleInstanceMutexName);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ShowRunningInstance();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"lingua_srs", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
