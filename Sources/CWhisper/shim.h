#ifndef CWHISPER_SHIM_H
#define CWHISPER_SHIM_H

// Resolved via -I<homebrew prefix>/include, set from Package.swift so this
// builds on both Apple silicon (/opt/homebrew) and Intel (/usr/local).
#include <whisper.h>

// ggml's compute backends (Metal, CPU) register themselves separately from
// libwhisper. Without ggml_backend_load_all(), whisper_init_from_file_with_params
// aborts inside make_buft_list with GGML_ASSERT(device) — there is no device to
// find. whisper-cli calls this at startup; so must we.
#include <ggml-backend.h>

#endif
