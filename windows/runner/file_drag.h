#ifndef RUNNER_FILE_DRAG_H_
#define RUNNER_FILE_DRAG_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

// Registers the "umbra_tags/drag" method channel. startFileDrag([paths]) runs
// a Windows drag-and-drop of the files (CF_HDROP, copy only, so the library's
// files are never moved) while the mouse button is still held. Replies true
// when something accepted the drop. `view` is the Flutter view window, which
// is sent the button-up that the drag loop consumed.
void RegisterFileDragChannel(flutter::BinaryMessenger* messenger, HWND view);

#endif  // RUNNER_FILE_DRAG_H_
