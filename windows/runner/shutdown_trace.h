#ifndef UMBRA_SHUTDOWN_TRACE_H_
#define UMBRA_SHUTDOWN_TRACE_H_

#include <windows.h>
#include <filesystem>
#include <fstream>

// Native timing starts at WM_CLOSE, before Dart receives the close event.
// Keep this separate from the Dart report, which ends before engine teardown.
inline void TraceNativeShutdown(const char* stage) noexcept {
  try {
    static const ULONGLONG started = GetTickCount64();
    static std::ofstream log([] {
      wchar_t local_app_data[32768];
      const DWORD length = GetEnvironmentVariableW(
          L"LOCALAPPDATA", local_app_data, 32768);
      if (length == 0 || length >= 32768) return std::filesystem::path();
      const auto directory = std::filesystem::path(local_app_data) / L"Umbra Tags";
      std::filesystem::create_directories(directory);
      return directory / L"native-shutdown.log";
    }(), std::ios::out | std::ios::trunc);
    if (log) {
      log << (GetTickCount64() - started) << " ms: " << stage << std::endl;
    }
  } catch (...) {
    // Diagnostics must never block exit on an inaccessible log directory.
  }
}

#endif
