#include <windows.h>
#include <ole2.h>
#include <shlobj.h>

#include "file_drag.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableValue;

HWND g_view = nullptr;

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

// A DROPFILES block: the header followed by double-null-terminated paths.
HGLOBAL CreateDropFiles(const std::vector<std::wstring>& paths) {
  size_t chars = 1;
  for (const auto& path : paths) chars += path.size() + 1;
  HGLOBAL handle =
      GlobalAlloc(GHND, sizeof(DROPFILES) + chars * sizeof(wchar_t));
  if (!handle) return nullptr;
  auto* drop = static_cast<DROPFILES*>(GlobalLock(handle));
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  auto* cursor = reinterpret_cast<wchar_t*>(drop + 1);
  for (const auto& path : paths) {
    memcpy(cursor, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
    cursor += path.size() + 1;
  }
  GlobalUnlock(handle);
  return handle;
}

bool SetGlobal(IDataObject* data, CLIPFORMAT format, HGLOBAL handle) {
  FORMATETC format_etc{format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium{};
  medium.tymed = TYMED_HGLOBAL;
  medium.hGlobal = handle;
  // On success the data object owns the handle.
  if (SUCCEEDED(data->SetData(&format_etc, &medium, TRUE))) return true;
  GlobalFree(handle);
  return false;
}

DWORD DragFiles(const std::vector<std::wstring>& paths) {
  OleInitialize(nullptr);  // Reference-counted; required by drag and drop.
  IDataObject* data = nullptr;
  if (FAILED(SHCreateDataObject(nullptr, 0, nullptr, nullptr,
                                IID_PPV_ARGS(&data)))) {
    return DROPEFFECT_NONE;
  }
  DWORD effect = DROPEFFECT_NONE;
  HGLOBAL files = CreateDropFiles(paths);
  if (files && SetGlobal(data, CF_HDROP, files)) {
    // Ask targets such as Explorer to copy rather than move.
    if (HGLOBAL preferred = GlobalAlloc(GHND, sizeof(DWORD))) {
      *static_cast<DWORD*>(GlobalLock(preferred)) = DROPEFFECT_COPY;
      GlobalUnlock(preferred);
      SetGlobal(data,
                static_cast<CLIPFORMAT>(
                    RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT)),
                preferred);
    }
    // Default drop source and drag image; runs a modal loop until the drop.
    SHDoDragDrop(g_view, data, nullptr, DROPEFFECT_COPY, &effect);
  }
  data->Release();
  // The drag loop consumed the button release, so Flutter would still think
  // the button is down. Deliver it at the current cursor position.
  POINT cursor;
  if (g_view && GetCursorPos(&cursor) && ScreenToClient(g_view, &cursor)) {
    PostMessageW(g_view, WM_LBUTTONUP, 0, MAKELPARAM(cursor.x, cursor.y));
  }
  return effect;
}

}  // namespace

void RegisterFileDragChannel(flutter::BinaryMessenger* messenger, HWND view) {
  g_view = view;
  // The channel must outlive this call; it lives for the app's lifetime.
  static std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "umbra_tags/drag",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "startFileDrag") {
          result->NotImplemented();
          return;
        }
        std::vector<std::wstring> paths;
        if (const auto* list = std::get_if<EncodableList>(call.arguments())) {
          for (const auto& value : *list) {
            const auto* path = std::get_if<std::string>(&value);
            std::wstring wide = path ? Utf16FromUtf8(*path) : std::wstring();
            if (!wide.empty()) paths.push_back(std::move(wide));
          }
        }
        if (paths.empty()) {
          result->Error("bad_args", "Expected file paths.");
          return;
        }
        result->Success(EncodableValue(DragFiles(paths) != DROPEFFECT_NONE));
      });
}
