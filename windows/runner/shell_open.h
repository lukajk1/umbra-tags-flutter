#ifndef RUNNER_SHELL_OPEN_H_
#define RUNNER_SHELL_OPEN_H_

#include <flutter/binary_messenger.h>

// Registers the "umbra_tags/shell" method channel. openFile(path) opens a file
// with its associated app on a worker thread, so a slow shell (first use in a
// session can take seconds) never blocks the UI thread. Replies true when the
// app launched, false when no app is associated with the file type.
void RegisterShellOpenChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SHELL_OPEN_H_
