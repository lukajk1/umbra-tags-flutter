#include <windows.h>
#include <objbase.h>
#include <shellapi.h>

#include "shell_open.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

constexpr UINT kShellFinished = WM_APP + 1;

// Method results must be completed on the platform thread, so workers post
// their outcome to this message-only window, which runs on that thread.
HWND g_reply_window = nullptr;
HWND g_owner = nullptr;

enum class ShellTask { kOpen, kRecycle };

struct PendingShellTask {
  ShellTask task;
  std::vector<std::wstring> paths;
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
  if (message != kShellFinished) {
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
  std::unique_ptr<PendingShellTask> pending(
      reinterpret_cast<PendingShellTask*>(lparam));
  if (pending->error == ERROR_SUCCESS) {
    pending->result->Success(EncodableValue(true));
  } else if (pending->task == ShellTask::kOpen &&
             pending->error == ERROR_NO_ASSOCIATION) {
    pending->result->Success(EncodableValue(false));
  } else if (pending->task == ShellTask::kRecycle &&
             pending->error == ERROR_CANCELLED) {
    pending->result->Error("recycle_cancelled",
                           "Moving the source files was cancelled.");
  } else {
    pending->result->Error(
        pending->task == ShellTask::kOpen ? "open_failed" : "recycle_failed",
        std::string(pending->task == ShellTask::kOpen
                        ? "Windows could not open this file"
                        : "Windows could not move the source files to the "
                          "Recycle Bin") +
            " (error " + std::to_string(pending->error) + ").");
  }
  return 0;
}

DWORD OpenFile(const std::wstring& path) {
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  // NOASYNC: this thread exits right after, so finish the launch here.
  info.fMask = SEE_MASK_NOASYNC;
  info.lpVerb = L"open";
  info.lpFile = path.c_str();
  info.nShow = SW_SHOWNORMAL;
  return ShellExecuteExW(&info) ? ERROR_SUCCESS : GetLastError();
}

DWORD RecycleFiles(const std::vector<std::wstring>& paths) {
  // SHFileOperation takes a double-null-terminated list of paths.
  std::wstring from;
  for (const auto& path : paths) {
    from += path;
    from.push_back(L'\0');
  }
  from.push_back(L'\0');
  SHFILEOPSTRUCTW operation{};
  operation.hwnd = g_owner;
  operation.wFunc = FO_DELETE;
  operation.pFrom = from.c_str();
  // Recycle without prompting, but warn before anything would be deleted
  // permanently (a drive without a Recycle Bin).
  operation.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_WANTNUKEWARNING |
                     FOF_SILENT | FOF_NOERRORUI;
  int status = SHFileOperationW(&operation);
  if (status != 0) return static_cast<DWORD>(status);
  return operation.fAnyOperationsAborted ? ERROR_CANCELLED : ERROR_SUCCESS;
}

void RunOnWorker(PendingShellTask* pending) {
  // Shell operations may use COM shell extensions; this is the documented setup.
  HRESULT com = CoInitializeEx(
      nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  pending->error = pending->task == ShellTask::kOpen
                       ? OpenFile(pending->paths.front())
                       : RecycleFiles(pending->paths);
  if (SUCCEEDED(com)) CoUninitialize();
  // If the window is gone the app is shutting down; the result is abandoned
  // rather than completed off the platform thread.
  if (!PostMessageW(g_reply_window, kShellFinished, 0,
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
  window_class.lpszClassName = L"UmbraTagsShellReply";
  RegisterClassW(&window_class);
  g_reply_window = CreateWindowExW(0, window_class.lpszClassName, L"", 0, 0, 0,
                                   0, 0, HWND_MESSAGE, nullptr,
                                   window_class.hInstance, nullptr);
  return g_reply_window != nullptr;
}

// Reads the call's paths: one string for openFile, a list for recycleFiles.
std::vector<std::wstring> PathsFrom(const EncodableValue* arguments) {
  std::vector<std::wstring> paths;
  auto add = [&paths](const EncodableValue& value) {
    const auto* path = std::get_if<std::string>(&value);
    std::wstring wide = path ? Utf16FromUtf8(*path) : std::wstring();
    // Only absolute drive or UNC paths; never an empty or relative entry.
    if (wide.size() < 3 ||
        !((wide[1] == L':' && wide[2] == L'\\') || wide.rfind(L"\\\\", 0) == 0)) {
      paths.clear();
      return false;
    }
    paths.push_back(std::move(wide));
    return true;
  };
  if (!arguments) return paths;
  if (const auto* list = std::get_if<EncodableList>(arguments)) {
    for (const auto& value : *list) {
      if (!add(value)) break;
    }
  } else {
    add(*arguments);
  }
  return paths;
}

}  // namespace

void RegisterShellOpenChannel(flutter::BinaryMessenger* messenger, HWND owner) {
  g_owner = owner;
  // The channel must outlive this call; it lives for the app's lifetime.
  static std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "umbra_tags/shell",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<Result> result) {
        ShellTask task;
        if (call.method_name() == "openFile") {
          task = ShellTask::kOpen;
        } else if (call.method_name() == "recycleFiles") {
          task = ShellTask::kRecycle;
        } else {
          result->NotImplemented();
          return;
        }
        auto paths = PathsFrom(call.arguments());
        if (paths.empty() || (task == ShellTask::kOpen && paths.size() != 1)) {
          result->Error("bad_args", "Expected absolute file paths.");
          return;
        }
        if (!EnsureReplyWindow()) {
          result->Error("shell_failed", "Could not prepare the shell request.");
          return;
        }
        auto* pending =
            new PendingShellTask{task, std::move(paths), std::move(result)};
        std::thread(RunOnWorker, pending).detach();
      });
}
