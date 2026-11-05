# FigmaCapture

Press one button in Figma and the screen your iOS app is showing appears as editable layers. It's the same idea as Figma's web capture extension, for native iOS apps. It works with SwiftUI and UIKit, and has no dependencies.

It has two parts:

- A **Swift package** that runs inside your app in debug builds and reads the live screen.
- A **Figma plugin** that turns that into frames, text, vectors and images.

## Add it to an app

1. In Xcode, go to File → Add Package Dependencies, and enter `https://github.com/KoolSingh/FigmaCapture`.
2. Call `start` once at launch:

```swift
#if DEBUG
import FigmaCapture
#endif

@main
struct MyApp: App {
    init() {
        #if DEBUG
        FigmaCapture.start(fontFamily: "Inter")
        #endif
    }
    // ...
}
```

`fontFamily` is your app's font as Figma lists it. Capture can't tell which font text uses, so all text gets this one.

UIKit apps make the same call in `application(_:didFinishLaunchingWithOptions:)`.

## Add the plugin to Figma (once)

The plugin isn't on Figma Community, so you import it from this repo:

1. Clone or download this repo.
2. In the Figma desktop app, go to Plugins → Development → Import plugin from manifest, and pick `FigmaPlugin/manifest.json`.

Keep the files in `FigmaPlugin/` together, because Figma loads `code.js` and `ui.html` from beside the manifest. If you move the folder, remove the plugin in Manage plugins in development and import it again. Importing again without removing it keeps the old path.

## Capture a screen

1. Run the app in the iOS Simulator and go to the screen you want.
2. In Figma, run Plugins → Development → App Capture.
3. Press **Capture screen**.

Each capture lands beside the last one on the page.

**On a real device:** the plugin can't reach the phone, because the server only listens on the device itself. Save the output of `FigmaCapture.captureJSON(fontFamily:)` to a file, send it to your Mac, and drop it on the plugin.

## What you get

- Frames with their real fills, gradients, corner radii, borders and shadows.
- Editable text, read from the screen with on-device text recognition.
- Vector icons where the app draws them as shapes. Other icons come as images.
- Things nested the way a designer would: a tile holds its icon, a label goes with its tile, and a line of tiles is a row.
- Auto layout on evenly spaced rows and columns. Anything uneven keeps its exact position.
- A shared colour style for each colour, under `Capture/`.

## Limits

- **Text is read from pixels,** so check it. Decorative fonts can misread, and very short text may come through as an image.
- **Text styles aren't kept.** All text uses one font, and its size is measured.
- **Blurs are approximate:** a solid colour taken from the screen plus a background blur.
- **Components aren't created.** Select a tile and create one in Figma.
- **Only the current screen,** without off-screen scroll content, the status bar or system sheets. Open what you want visible first.
- **Motion and gestures** don't transfer.
- SwiftUI's internal layers can change between iOS versions. Tested on an iOS 18.3 Simulator with a SwiftUI app. UIKit apps and real devices are untested.

## Privacy

The server listens on the loopback interface only, and refuses requests from web pages, so a site open in your browser can't read your screen. Keep `start()` inside `#if DEBUG`.

## Testing the plugin without Figma

```bash
node FigmaPlugin/mock-test.js capture.json
```

This runs the plugin against a stand-in for Figma's API. It catches crashes and shows the auto layout decisions, but it can't show how the result looks.

## License

MIT. See `LICENSE`.
