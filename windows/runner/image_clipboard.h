#ifndef RUNNER_IMAGE_CLIPBOARD_H_
#define RUNNER_IMAGE_CLIPBOARD_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

// Registers the "umbra_tags/clipboard" method channel, which copies an image
// file to the Windows clipboard as a bitmap (CF_DIB) and as PNG data.
void RegisterImageClipboardChannel(flutter::BinaryMessenger* messenger,
                                   HWND owner);

#endif  // RUNNER_IMAGE_CLIPBOARD_H_
