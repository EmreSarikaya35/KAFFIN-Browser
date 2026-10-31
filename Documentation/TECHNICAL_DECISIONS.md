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

Confirmed by the project owner in the app: Google account sign-in works, and Amazon Prime Video plays series.

Still open: Microsoft sign-in, tab mute, password manager and ad blocker extensions.

## Persistence

GRDB.swift 7.11 in WAL mode, behind `ProfileDatabase`. The file lives in `Application Support/KAFFIN/Profiles/<id>/profile.sqlite`, inside the sandbox container.

File paths passed to SQLite or `FileManager` must use `path(percentEncoded: false)`. Plain `path()` turns the space in `Application Support` into `%20`.

Only the default profile exists so far, so the application database and folder tables from the plan are not created yet.

## Downloads in the sandbox

WebKit's network process cannot write to `~/Downloads` under App Sandbox. The download stalls with no error, and no sandbox denial is logged for the file. Downloads are staged in the container, marked with `com.apple.quarantine`, then moved by the app, which holds the Downloads entitlement. Verified in the sandboxed Release app on macOS 27.0.1.

## Passwords

Passwords live only in the Keychain, one service per profile. Login detection runs in an isolated `WKContentWorld`, main frame only, and never in private windows. Logins match the exact origin, plain http is refused apart from loopback, and saving or filling always takes a click. Showing a saved password requires Touch ID or the Mac password.

Keychain use was verified in the sandboxed Release app. Ad hoc signatures change on each build, so macOS may ask for Keychain access again after rebuilding, until Developer ID signing arrives.

## Favicons

WebKit has no favicon API. Declared icons are read in the default client world, with `/favicon.ico` as the fallback. An ephemeral session fetches them with no cookies, and each host is tried once per launch. Icons are re-encoded to small PNGs and stored by host and port. Private windows fetch no icons.

## Web pages and downloads

`www.youtube.com.html` was once saved instead of shown. The file was a complete, ordinary YouTube home page, so WebKit must have reported a real page as not showable. HTML and XHTML now download only when the server sends `Content-Disposition: attachment`. If WebKit really cannot show one, the navigation fails to the error page instead of leaving a surprise file. The trigger was not reproduced, so main frame decisions with `canShow=false` or a download are logged for evidence.

## Address bar completion

History is grouped by site, with `www.` removed, and visits add up across pages, so a site's many pages count toward it. Enter opens the top site row only while the field still holds the typed text or its completion. After a deletion, no completion runs and Enter keeps the remaining text.

## Chrome layout

The tab strip fills the titlebar area, so the chrome's hosting view uses `safeAreaRegions = []`. Otherwise SwiftUI pushes the content down by the titlebar's safe area, past the height constraint and over the top of the page. Verified with a numbered ruler page, with the bookmarks bar off and toggled on live.

## Bookmark files

Import and export use the Netscape bookmark HTML format. The file is outside data: only http and https addresses are kept, nesting is capped at 32 levels, and files over 50 MB are refused. Import runs in one transaction, skips addresses already saved, and merges folders with the same name and parent. Chrome's bookmarks bar folder maps to the KAFFIN bar root.

## Profiles

`ProfileSession` owns one profile's data store, database, Keychain service, bookmarks, history, downloads, and its History and Settings windows. The default profile keeps its original identifier, so existing data stays in place.

The profile list is stored in UserDefaults rather than the planned application database, because it is a short list with no relations. The default profile cannot be deleted. Deleting a profile removes its Keychain items, WebKit data store, and database folder, after its windows close. This was verified in the sandboxed Release app.

Search engine and appearance remain app-wide, although the plan lists preferences per profile.

## Tab sleeping

Sleeping swaps the tab's WKWebView for a new one with no page, keeping the saved state in memory. The `Tab` object stays, so `webView` is never optional. Selecting the tab restores it through the same path as session restore.

Automatic sleeping is gated in `TabManager.sleepEligibleTabs` by `PerformanceSettings`: Standard allows nothing, and `TabSleepScheduler` starts no timer or memory listener. Any media state other than none counts as media, because WebKit's playing and paused values proved unreliable.

Measured in the sandboxed Release app with two heavy pages and one muted audio page: WebKit content went from 3 processes and 704 MB to 1 process and 29 MB. The audio tab stayed awake. Windowless tests cannot load media, so this protection rests on that measurement and the `SleepPolicy` unit tests.

## Extensions

KAFFIN hosts WebKit's runtime: `ExtensionHost` owns one `WKWebExtensionController` per profile, and adapters present tabs and windows to it. Packages are copied into the profile's `Extensions` folder, with an `index.json` holding enabled state and granted permissions, because WebKit does not store those grants. This is a JSON file rather than planned SQLite tables, so it deletes with the profile.

The store's Add button works only in Chrome, so a listing address or ID downloads the CRX directly. Whether that fits the Chrome Web Store terms needs a decision before public release.

## Fraudulent website warnings

WebKit's warning needs the sandbox to reach `com.apple.Safari.SafeBrowsing.Service`, granted by a temporary-exception entitlement. Without it the warning never appeared, although the preference was on. With it, Google's phishing test page logged `threat found`, and it was not recorded in history. This entitlement would need review for the Mac App Store, which is out of scope.

## Site permissions

Camera, microphone, and location decisions are stored per origin in the profile database, and listed in Settings. Private windows have no store, so they ask every time and keep nothing. Without a window to ask in, the answer is no.

## Editing a database by hand

The `sqlite3` tool leaves foreign keys off by default. Deleting history there leaves orphan visit rows, and GRDB then refuses the next migration, so the profile opens without saved data. Always start with `PRAGMA foreign_keys=ON`. This happened to a test copy only.

## Navigation policy

`LinkPolicy` decides every navigation: `file:` and script addresses never open, `data:` cannot fill the window, and other apps open only after a click and a confirmation. Page dialogs and HTTP sign-in name the site. Certificate checks stay with WebKit, so a bad certificate fails. Each decision is covered by a test, except that a real link click to another app was not exercised.

## Signing

Debug builds are ad hoc signed without the hardened runtime flag, which Xcode omits for that configuration. Release builds carry it (`flags=0x10002(adhoc,runtime)`) and launch under the sandbox. Developer ID signing is unverified until Phase 8.

## Testing

Swift Testing needs the full Xcode toolchain because Command Line Tools lack its macro plugin. Run tests with `swift test` in `KaffinKit/`.

## Page Location

`WKWebView` on macOS calls the geolocation permission delegate but provides no location. KAFFIN replaces `Geolocation.prototype` in the main frame and answers from `CLLocationManager`. The page script talks to an isolated world through window events, because a page-world message handler would expose `window.webkit`.
