import AppKit
import OpenGL.GL3

/// Draws an in-process mpv core's video (libmpv's OpenGL render API) into a layer. The render
/// context is created up front, so mpv's video output exists before the first file loads, and
/// must be freed with `release()` before the core is destroyed.
final class MPVVideoLayer: CAOpenGLLayer {
    private let api: LibMPV
    private let pixelFormat: CGLPixelFormatObj
    private let glContext: CGLContextObj
    /// Only touched on the main thread (drawing and `release()` both happen there).
    private var renderContext: LibMPV.RenderContext?

    init(core: MPVCore) throws {
        api = core.api
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize, CGLPixelFormatAttribute(24), kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var formatCount: GLint = 0
        guard CGLChoosePixelFormat(attributes, &format, &formatCount) == kCGLNoError, let format else {
            throw StowError.player("No OpenGL pixel format for the video.")
        }
        var context: CGLContextObj?
        guard CGLCreateContext(format, nil, &context) == kCGLNoError, let context else {
            CGLReleasePixelFormat(format)
            throw StowError.player("Couldn't create an OpenGL context for the video.")
        }
        pixelFormat = format
        glContext = context
        super.init()
        isAsynchronous = false
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        needsDisplayOnBoundsChange = true

        CGLSetCurrentContext(context)
        defer { CGLSetCurrentContext(nil) }
        var initParams = mpv_opengl_init_params(get_proc_address: { _, name in
            guard let name else { return nil }
            return dlsym(openGLLibrary, name)
        }, get_proc_address_ctx: nil)
        var renderContext: LibMPV.RenderContext?
        let status = MPV_RENDER_API_TYPE_OPENGL.withCString { apiType in
            withUnsafeMutablePointer(to: &initParams) { initPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return api.renderContextCreate(&renderContext, core.handle, &params)
            }
        }
        guard status >= 0, let renderContext else {
            CGLReleaseContext(context)
            CGLReleasePixelFormat(format)
            throw StowError.player("mpv couldn't draw into the window: \(api.describe(status)).")
        }
        self.renderContext = renderContext
        api.renderContextSetUpdateCallback(renderContext, { context in
            guard let context else { return }
            let layer = Unmanaged<MPVVideoLayer>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { layer.frameReady() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Core Animation makes copies of layers for animations; they never draw video.
    override init(layer: Any) {
        let other = layer as? MPVVideoLayer
        api = other?.api ?? (try! LibMPV.load())
        pixelFormat = CGLRetainPixelFormat(other!.pixelFormat)
        glContext = CGLRetainContext(other!.glContext)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        CGLReleaseContext(glContext)
        CGLReleasePixelFormat(pixelFormat)
    }

    /// Frees the render context (mpv's video output stops). Call before the core is destroyed.
    func release() {
        guard let renderContext else { return }
        self.renderContext = nil
        CGLSetCurrentContext(glContext)
        api.renderContextSetUpdateCallback(renderContext, nil, nil)
        api.renderContextFree(renderContext)
        CGLSetCurrentContext(nil)
    }

    private func frameReady() {
        guard let renderContext else { return }
        if api.renderContextUpdate(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
            setNeedsDisplay()
        }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(pixelFormat)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(glContext)
    }

    override func draw(inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj,
                       forLayerTime layerTime: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?) {
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            glFlush()
            return
        }
        var target = mpv_opengl_fbo(fbo: Int32(framebuffer), w: Int32(viewport[2]), h: Int32(viewport[3]),
                                    internal_format: 0)
        var flipY: Int32 = 1
        // This runs on the main thread: never wait here for the frame's display time (mpv would
        // block up to a frame per draw, stalling every click, scroll and hover in the app).
        // `video-timing-offset=0` (MPVPlayer) keeps the video in sync without the wait.
        var blockForTargetTime: Int32 = 0
        withUnsafeMutablePointer(to: &target) { targetPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(targetPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
                                         data: UnsafeMutableRawPointer(blockPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = api.renderContextRender(renderContext, &params)
                }
            }
        }
        glFlush()
    }
}

private let openGLLibrary = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
