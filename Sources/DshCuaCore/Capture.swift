import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Window-scoped capture only.
///
/// The rule that makes this tool tolerable to live with: we never grab the whole display.
/// A full-display capture is both a privacy problem and a focus/UX problem, and it is
/// unnecessary — ScreenCaptureKit can render a single window off-screen without
/// bringing it forward.
public enum Capture {
    public static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    public struct Result {
        public let path: String
        public let width: Int
        public let height: Int
        public let windowId: CGWindowID
        public let scale: Double
    }

    /// Captures exactly one window to `path` as PNG.
    /// - Parameter scale: backing scale factor; 2.0 gives retina-sharp output.
    public static func window(
        id: CGWindowID,
        to path: String,
        scale: Double = 2.0
    ) async throws -> Result {
        guard hasPermission else {
            throw CuaError(
                .permissionDenied,
                "Screen Recording permission is not granted for this binary",
                detail: [
                    "hint": "System Settings → Privacy & Security → Screen & System Audio Recording",
                    "binary": Bundle.main.executablePath ?? CommandLine.arguments.first ?? "dsh-cua",
                ]
            )
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CuaError(
                .permissionDenied,
                "ScreenCaptureKit could not enumerate windows: \(error.localizedDescription)",
                detail: ["hint": "grant Screen Recording to the dsh-cua binary"]
            )
        }

        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CuaError(
                .windowNotFound,
                "ScreenCaptureKit does not know window \(id)",
                detail: ["hint": "the window may have closed since it was listed"]
            )
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CuaError(
                .permissionDenied,
                "window capture failed: \(error.localizedDescription)",
                detail: ["windowId": Int(id)]
            )
        }

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CuaError(.internal, "could not create PNG destination at \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CuaError(.internal, "could not write PNG to \(path)")
        }

        return Result(
            path: url.path,
            width: image.width,
            height: image.height,
            windowId: id,
            scale: scale
        )
    }
}
