#ifndef RUNNER_SHELL_OPEN_H_
#define RUNNER_SHELL_OPEN_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

// Registers the "umbra_tags/shell" method channel. Shell calls run on a worker
// thread, so a slow shell (first use in a session can take seconds) never
// blocks the UI thread.
// - openFile(path): opens a file with its associated app. Replies true when
//   the app launched, false when no app is associated with the file type.
// - recycleFiles([paths]): moves files to the Recycle Bin, warning before any
//   permanent deletion. Replies true, or an error if cancelled or failed.
// `owner` parents any shell warning dialogs.
void RegisterShellOpenChannel(flutter::BinaryMessenger* messenger, HWND owner);

#endif  // RUNNER_SHELL_OPEN_H_
