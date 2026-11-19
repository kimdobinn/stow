import Foundation

/// The libmpv functions Stow uses, looked up at runtime from Homebrew's mpv. Loading it lazily
/// (instead of linking) means a missing or upgraded mpv only breaks video playback, which the
/// alarm reports and covers with its alarm sound, not the whole app.
struct LibMPV: @unchecked Sendable {
    typealias Handle = OpaquePointer
    typealias RenderContext = OpaquePointer

    let create: @convention(c) () -> Handle?
    let setOptionString: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let initialize: @convention(c) (Handle?) -> Int32
    let command: @convention(c) (Handle?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    let waitEvent: @convention(c) (Handle?, Double) -> UnsafeMutablePointer<mpv_event>?
    let wakeup: @convention(c) (Handle?) -> Void
    let terminateDestroy: @convention(c) (Handle?) -> Void
    let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>?
    let renderContextCreate: @convention(c) (UnsafeMutablePointer<RenderContext?>?, Handle?,
                                             UnsafeMutablePointer<mpv_render_param>?) -> Int32
    let renderContextSetUpdateCallback: @convention(c) (RenderContext?, mpv_render_update_fn?, UnsafeMutableRawPointer?) -> Void
    let renderContextUpdate: @convention(c) (RenderContext?) -> UInt64
    let renderContextRender: @convention(c) (RenderContext?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    let renderContextFree: @convention(c) (RenderContext?) -> Void

    static let candidates = ["/opt/homebrew/lib/libmpv.2.dylib", "/opt/homebrew/lib/libmpv.dylib",
                             "/usr/local/lib/libmpv.2.dylib", "/usr/local/lib/libmpv.dylib"]

    private static let loaded: Result<LibMPV, StowError> = {
        guard let library = candidates.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else {
            return .failure(.player("libmpv isn't installed (brew install mpv)."))
        }
        func symbol<T>(_ name: String, as _: T.Type = T.self) throws -> T {
            guard let pointer = dlsym(library, name) else { throw StowError.player("libmpv has no \(name).") }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            return .success(LibMPV(
                create: try symbol("mpv_create"),
                setOptionString: try symbol("mpv_set_option_string"),
                initialize: try symbol("mpv_initialize"),
                command: try symbol("mpv_command"),
                waitEvent: try symbol("mpv_wait_event"),
                wakeup: try symbol("mpv_wakeup"),
                terminateDestroy: try symbol("mpv_terminate_destroy"),
                errorString: try symbol("mpv_error_string"),
                renderContextCreate: try symbol("mpv_render_context_create"),
                renderContextSetUpdateCallback: try symbol("mpv_render_context_set_update_callback"),
                renderContextUpdate: try symbol("mpv_render_context_update"),
                renderContextRender: try symbol("mpv_render_context_render"),
                renderContextFree: try symbol("mpv_render_context_free")))
        } catch let error as StowError {
            return .failure(error)
        } catch {
            return .failure(.player(error.localizedDescription))
        }
    }()

    /// Throws `.player` when libmpv can't be loaded.
    static func load() throws -> LibMPV {
        try loaded.get()
    }

    func describe(_ status: Int32) -> String {
        errorString(status).map { String(cString: $0) } ?? "error \(status)"
    }

    /// Runs an mpv command given as strings, e.g. ["loadfile", url, "append-play"].
    @discardableResult
    func run(_ handle: Handle, _ arguments: [String]) -> Int32 {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        defer { pointers.forEach { free(UnsafeMutableRawPointer(mutating: $0)) } }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { command(handle, $0.baseAddress) }
    }
}
