# Technical Decisions

## Project layout

- Modules live in one local Swift Package, `KaffinKit/`, with targets `BrowserCore`, `Tabs`, `BrowserUI`, and `Browser`. The plan's top-level folders are introduced as targets when needed.
- The UI target is named `BrowserUI`, because `UI` is too generic to import.
- The Xcode project is a thin app target that uses a folder-synchronized `App/` group.

## Phase 0 results (macOS 27.0.1, 2026-10-31)

Measured with a throwaway unbundled, unsandboxed program. Results must be repeated in the signed, sandboxed app.

| Question                    | Result                                                                                         |
| --------------------------- | ---------------------------------------------------------------------------------------------- |
| Default user agent          | Confirmed: no Safari token. `WebViewFactory` now adds `Version/<os> Safari/605.1.15`            |
| Download after WebView release | Confirmed working: a 6-second download finished at full size after the WebView was released |
| MV3 extension load          | Confirmed: `WKWebExtension` loaded a local MV3 extension and its content script ran             |
| Extension messaging         | Blocked as expected: `runtime.sendMessage` reports "Tab not found" until `WKWebExtensionTab` is implemented (Phase 5) |
| `Notification` in page      | The constructor exists. Permission and delivery are untested. `PushManager` is undefined        |
| Geolocation, PiP, EME, WebAuthn | The JavaScript APIs exist. Actual behavior is untested                                     |
| Media playback state        | Inconclusive: `requestMediaPlaybackState` returned 1 both before and after `play()`             |

Still open, and each needs manual use of the app: Google and Microsoft sign-in, DRM streaming, tab mute, password manager and ad blocker extensions.

## Signing

Debug builds are ad hoc signed without the hardened runtime flag, which Xcode omits for that configuration. Release builds carry it (`flags=0x10002(adhoc,runtime)`) and launch under the sandbox. Developer ID signing is unverified until Phase 8.

## Testing

Swift Testing needs the full Xcode toolchain because Command Line Tools lack its macro plugin. Run tests with `swift test` in `KaffinKit/`.
