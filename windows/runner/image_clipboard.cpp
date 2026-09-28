#include <windows.h>
#include <objidl.h>
#include <shlwapi.h>

// GDI+ headers expect min/max, which NOMINMAX removes.
#include <algorithm>
using std::max;
using std::min;
#include <gdiplus.h>

#include "image_clipboard.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

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

bool FindPngEncoder(CLSID* clsid) {
  UINT count = 0, size = 0;
  if (Gdiplus::GetImageEncodersSize(&count, &size) != Gdiplus::Ok || size == 0)
    return false;
  std::vector<BYTE> buffer(size);
  auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  if (Gdiplus::GetImageEncoders(count, size, codecs) != Gdiplus::Ok)
    return false;
  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(codecs[i].MimeType, L"image/png") == 0) {
      *clsid = codecs[i].Clsid;
      return true;
    }
  }
  return false;
}

HGLOBAL GlobalFromBytes(const void* data, size_t size) {
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!handle) return nullptr;
  void* target = GlobalLock(handle);
  if (!target) {
    GlobalFree(handle);
    return nullptr;
  }
  memcpy(target, data, size);
  GlobalUnlock(handle);
  return handle;
}

// Builds a 24-bit bottom-up CF_DIB, composited onto white so transparent
// regions paste sensibly into apps that ignore alpha.
HGLOBAL CreateDib(Gdiplus::Bitmap& source) {
  const UINT width = source.GetWidth(), height = source.GetHeight();
  Gdiplus::Bitmap flat(width, height, PixelFormat24bppRGB);
  {
    Gdiplus::Graphics graphics(&flat);
    graphics.Clear(Gdiplus::Color(255, 255, 255, 255));
    graphics.DrawImage(&source, 0, 0, static_cast<INT>(width),
                       static_cast<INT>(height));
  }
  Gdiplus::Rect rect(0, 0, static_cast<INT>(width), static_cast<INT>(height));
  Gdiplus::BitmapData data{};
  if (flat.LockBits(&rect, Gdiplus::ImageLockModeRead, PixelFormat24bppRGB,
                    &data) != Gdiplus::Ok)
    return nullptr;
  const size_t stride = ((width * 3 + 3) / 4) * 4;
  const size_t imageSize = stride * height;
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPINFOHEADER) + imageSize);
  if (handle) {
    auto* header = static_cast<BITMAPINFOHEADER*>(GlobalLock(handle));
    *header = {};
    header->biSize = sizeof(BITMAPINFOHEADER);
    header->biWidth = static_cast<LONG>(width);
    header->biHeight = static_cast<LONG>(height);
    header->biPlanes = 1;
    header->biBitCount = 24;
    header->biCompression = BI_RGB;
    header->biSizeImage = static_cast<DWORD>(imageSize);
    auto* pixels = reinterpret_cast<BYTE*>(header + 1);
    auto* scan0 = static_cast<BYTE*>(data.Scan0);
    for (UINT y = 0; y < height; ++y) {
      memcpy(pixels + (height - 1 - y) * stride, scan0 + y * data.Stride,
             width * 3);
    }
    GlobalUnlock(handle);
  }
  flat.UnlockBits(&data);
  return handle;
}

HGLOBAL CreatePng(Gdiplus::Bitmap& source) {
  CLSID encoder;
  if (!FindPngEncoder(&encoder)) return nullptr;
  IStream* stream = SHCreateMemStream(nullptr, 0);
  if (!stream) return nullptr;
  HGLOBAL result = nullptr;
  if (source.Save(stream, &encoder, nullptr) == Gdiplus::Ok) {
    STATSTG stat{};
    if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME))) {
      std::vector<BYTE> bytes(static_cast<size_t>(stat.cbSize.QuadPart));
      LARGE_INTEGER zero{};
      ULONG read = 0;
      if (SUCCEEDED(stream->Seek(zero, STREAM_SEEK_SET, nullptr)) &&
          SUCCEEDED(stream->Read(bytes.data(), static_cast<ULONG>(bytes.size()),
                                 &read)) &&
          read == bytes.size()) {
        result = GlobalFromBytes(bytes.data(), bytes.size());
      }
    }
  }
  stream->Release();
  return result;
}

std::string CopyImageFile(const std::wstring& path, HWND owner) {
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  if (Gdiplus::GdiplusStartup(&token, &input, nullptr) != Gdiplus::Ok)
    return "Could not start GDI+.";
  std::string error;
  {
    Gdiplus::Bitmap bitmap(path.c_str());
    if (bitmap.GetLastStatus() != Gdiplus::Ok || bitmap.GetWidth() == 0) {
      error = "Could not decode the image.";
    } else {
      HGLOBAL dib = CreateDib(bitmap);
      HGLOBAL png = CreatePng(bitmap);
      if (!dib) {
        error = "Could not convert the image.";
      } else if (!OpenClipboard(owner)) {
        error = "The clipboard is in use by another application.";
      } else {
        EmptyClipboard();
        if (SetClipboardData(CF_DIB, dib)) dib = nullptr;
        UINT pngFormat = RegisterClipboardFormatW(L"PNG");
        if (png && pngFormat && SetClipboardData(pngFormat, png)) png = nullptr;
        CloseClipboard();
        if (dib) error = "Could not place the image on the clipboard.";
      }
      if (dib) GlobalFree(dib);
      if (png) GlobalFree(png);
    }
  }
  Gdiplus::GdiplusShutdown(token);
  return error;
}

}  // namespace

void RegisterImageClipboardChannel(flutter::BinaryMessenger* messenger,
                                   HWND owner) {
  // The channel must outlive this call; it lives for the app's lifetime.
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "umbra_tags/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [owner](const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result) {
        if (call.method_name() != "copyImage") {
          result->NotImplemented();
          return;
        }
        const auto* path = std::get_if<std::string>(call.arguments());
        if (!path) {
          result->Error("bad_args", "Expected an image file path.");
          return;
        }
        std::string error = CopyImageFile(Utf16FromUtf8(*path), owner);
        if (error.empty()) {
          result->Success();
        } else {
          result->Error("copy_failed", error);
        }
      });
}
