import Foundation

// ---------------------------------------------------------------------------
// Constants — shared build-time constants for the OpenVerb app.
//
// DEFAULT_SOCKET_PATH  : Unix-domain socket for IPC with openverb-engine.
// DEFAULT_MODEL_DIR    : Directory scanned for .gguf model files at launch.
// CHUNK_BYTES          : PCM frame size delivered to the engine (4096 bytes =
//                        128 ms at 16 kHz / 16-bit / mono).
// ---------------------------------------------------------------------------

enum Constants {

    // Resolves "~" at runtime — FileManager.homeDirectoryForCurrentUser is
    // safe to call from any thread and correctly handles sandbox containers.
    static var DEFAULT_SOCKET_PATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.openverb/engine.sock"
    }

    static var DEFAULT_MODEL_DIR: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.openverb/models/"
    }

    /// Binary audio frame size in bytes (4096 bytes = 128 ms at 16 kHz/16-bit/mono).
    static let CHUNK_BYTES = 4096
}
