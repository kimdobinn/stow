// The embedded CPython, as a small C API that Swift can call without the Python headers.
// Swift (PythonRuntime.swift) is the only caller.
#ifndef STOW_PYTHON_H
#define STOW_PYTHON_H

#include <stdbool.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

/// Python reports a call's progress, result or failure. `kind` is "progress", "result", "error" or
/// "cancelled"; `payload` is UTF-8 JSON (or empty). Called on a Python thread with the GIL held:
/// copy what you need and return quickly, without calling back into Python.
typedef void (*StowPyEventHandler)(int64_t callID, const char *kind, const char *payload, int64_t payloadLength);

/// Whether a call was cancelled (checked by yt-dlp's progress hook and before each HTTP request).
typedef bool (*StowPyCancelCheck)(int64_t callID);

/// Runs a script in JavaScriptCore and returns what it printed with console.log, malloc'd. On
/// failure returns NULL and sets `*error` to a malloc'd message. Called without the GIL.
typedef char *_Nullable (*StowJSEvaluator)(const char *script, char *_Nullable *_Nonnull error);

typedef struct {
    /// Python's home: contains lib/python3.x.
    const char *home;
    /// Installed packages (yt-dlp, certifi), added with site.addsitedir.
    const char *sitePackages;
    /// The app's own modules (stow_ytdlp.py).
    const char *appPath;
    /// Writable folder for compiled bytecode (the app bundle is read-only).
    const char *pycachePrefix;
    /// Writable folder for yt-dlp's cache (player JavaScript, signatures).
    const char *cacheDir;
    StowPyEventHandler onEvent;
    StowPyCancelCheck isCancelled;
    StowJSEvaluator evaluateJS;
} StowPyConfig;

/// Starts the interpreter and imports stow_ytdlp. Call once, from the thread that will submit calls.
/// Returns NULL on success, or a malloc'd error message. Leaves the GIL released.
char *_Nullable stow_py_start(const StowPyConfig *config);

/// Hands a request (UTF-8 JSON) to Python, which runs it on a thread of its own and answers
/// through `onEvent`. Returns NULL, or a malloc'd error message when Python refused it.
char *_Nullable stow_py_submit(int64_t callID, const char *requestJSON);

/// Frees a string returned by the functions above.
void stow_py_free(void *_Nullable pointer);

#pragma clang assume_nonnull end

#endif
