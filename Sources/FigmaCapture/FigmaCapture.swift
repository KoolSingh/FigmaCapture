import UIKit

/// Brings an app's live screen into Figma as editable layers. Call `FigmaCapture.start()` once at
/// launch, inside `#if DEBUG`, then press Capture in the Figma plugin.
public enum FigmaCapture {
    private static var server: CaptureServer?

    /// Serves the screen on localhost, which the Simulator shares with the Mac.
    /// - Parameter fontFamily: the app's font as Figma knows it, such as "Inter". Capture reads
    ///   text from pixels and can't tell the font, so Figma uses this one for all text.
    public static func start(port: UInt16 = 8765, fontFamily: String? = nil) {
        guard server == nil else { return }
        server = CaptureServer(port: port, fontFamily: fontFamily)
        server?.start()
    }

    /// The current screen as capture JSON, to save to a file or share from a real device.
    /// The plugin imports the file.
    @MainActor public static func captureJSON(fontFamily: String? = nil) -> Data {
        ScreenCapture(fontFamily: fontFamily).run()
    }
}
