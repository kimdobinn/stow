// libmpv's C types (headers vendored from Homebrew mpv 0.42). The library itself is loaded at
// runtime with dlopen (LibMPV.swift), so Stow still launches when mpv isn't installed.
#include "mpv/client.h"
#include "mpv/render_gl.h"
