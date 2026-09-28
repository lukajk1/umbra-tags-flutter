#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "shutdown_trace.h"

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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Umbra Tags", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // The quit message is posted only after Dart has saved settings, stopped
  // workers and closed the library. Hide now; do not leave a frozen window up
  // while graphics resources and plugins are being released.
  if (window.GetHandle()) ::ShowWindow(window.GetHandle(), SW_HIDE);
  TraceNativeShutdown("window hidden; native teardown starting");
  // Release Flutter/plugin COM resources while COM is still initialized.
  // Relying on the stack destructor here previously reversed this order.
  window.Destroy();
  TraceNativeShutdown("window and Flutter destroyed; COM cleanup starting");
  ::CoUninitialize();
  TraceNativeShutdown("COM cleanup complete; process returning");
  return EXIT_SUCCESS;
}
