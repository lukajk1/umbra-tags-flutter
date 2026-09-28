#include <windows.h>
#include <objbase.h>
#include <shellapi.h>

#include "shell_open.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <thread>

namespace {

using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

constexpr UINT kOpenFinished = WM_APP + 1;

// Method results must be completed on the platform thread, so workers post
// their outcome to this message-only window, which runs on that thread.
HWND g_reply_window = nullptr;

struct PendingOpen {
  std::wstring path;
  std::unique_ptr<Result> result;
  DWORD error = ERROR_SUCCESS;
};

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                      static_cast<int>(utf8.size()), result.data(), length);
  return result;
}

LRESULT CALLBACK ReplyWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  if (message != kOpenFinished) {
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
  std::unique_ptr<PendingOpen> pending(reinterpret_cast<PendingOpen*>(lparam));
  if (pending->error == ERROR_SUCCESS) {
    pending->result->Success(EncodableValue(true));
  } else if (pending->error == ERROR_NO_ASSOCIATION) {
    pending->result->Success(EncodableValue(false));
  } else {
    pending->result->Error("open_failed",
                           "Windows could not open this file (error " +
                               std::to_string(pending->error) + ").");
  }
  return 0;
}

void OpenOnWorker(PendingOpen* pending) {
  // ShellExecuteEx may use COM shell extensions; this is the documented setup.
  HRESULT com = CoInitializeEx(
      nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  // NOASYNC: this thread exits right after, so finish the launch here.
  info.fMask = SEE_MASK_NOASYNC;
  info.lpVerb = L"open";
  info.lpFile = pending->path.c_str();
  info.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&info)) pending->error = GetLastError();
  if (SUCCEEDED(com)) CoUninitialize();
  // If the window is gone the app is shutting down; the result is abandoned
  // rather than completed off the platform thread.
  if (!PostMessageW(g_reply_window, kOpenFinished, 0,
                    reinterpret_cast<LPARAM>(pending))) {
    pending->result.release();
    delete pending;
  }
}

bool EnsureReplyWindow() {
  if (g_reply_window) return true;
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = ReplyWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = L"UmbraTagsShellOpenReply";
  RegisterClassW(&window_class);
  g_reply_window = CreateWindowExW(0, window_class.lpszClassName, L"", 0, 0, 0,
                                   0, 0, HWND_MESSAGE, nullptr,
                                   window_class.hInstance, nullptr);
  return g_reply_window != nullptr;
}

}  // namespace

void RegisterShellOpenChannel(flutter::BinaryMessenger* messenger) {
  // The channel must outlive this call; it lives for the app's lifetime.
  static std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "umbra_tags/shell",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<Result> result) {
        if (call.method_name() != "openFile") {
          result->NotImplemented();
          return;
        }
        const auto* path = std::get_if<std::string>(call.arguments());
        std::wstring wide = path ? Utf16FromUtf8(*path) : std::wstring();
        if (wide.empty()) {
          result->Error("bad_args", "Expected a file path.");
          return;
        }
        if (!EnsureReplyWindow()) {
          result->Error("open_failed", "Could not prepare to open the file.");
          return;
        }
        auto* pending = new PendingOpen{std::move(wide), std::move(result)};
        std::thread(OpenOnWorker, pending).detach();
      });
}
