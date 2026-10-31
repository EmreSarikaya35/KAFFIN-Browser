# Extension Compatibility

Only what was actually run is listed. A claim here needs a test that was run on the supported macOS.

## Tested extensions

| Extension              | Version        | Source             | Result  | Notes |
| ---------------------- | -------------- | ------------------ | ------- | ----- |
| uBlock Origin Lite     | 2026.1026.1812 | Chrome Web Store   | Partial | Blocked a real ad request in the sandboxed Release app, from the second launch after install. Its popup and filter settings were not used. |
| KAFFIN test extension  | 1.2            | Test suite         | Works   | MV3 worker, content script, messaging, `storage`, `tabs.query`, `tabs.create`. |

## API support on macOS 27

| API or feature          | Status       | Evidence |
| ----------------------- | ------------ | -------- |
| Service worker          | Works        | Test extension, uBlock Origin Lite |
| Content scripts         | Works        | Test extension |
| `runtime` messaging     | Works        | Test extension |
| `storage`               | Works        | Test extension |
| `tabs.query`, `tabs.create` | Works    | Test extension |
| `declarativeNetRequest` | Works        | uBlock Origin Lite |
| CRX 3 packages          | Works        | uBlock Origin Lite |
| ZIP packages, folders   | Works        | Test suite |
| Action popup            | Works        | Opened by the project owner with uBlock Origin Lite |
| `action.setBadgeText`   | Works        | Test extension, shown in the toolbar model |
| `contextMenus`          | Works        | Test extension, read from WebKit; a real right-click was not exercised |
| `notifications`, `downloads`, `identity`, `debugger` | Not in the SDK permission list | Expect these to fail |
| `offscreen`, `userScripts` | Unknown   | Requested by uBlock Origin Lite, behavior not checked |
| Safari app extensions   | Not built    | WebKit can load them; KAFFIN has no install path |

## Chrome Web Store

Extension pages show an Add to KAFFIN button in the window's corner. The store's own Add to Chrome button stays grey, because the store allows it only in Chrome. In the sandboxed Release app, the same install path downloaded uBlock Origin Lite from Google and recorded its store identifier, and the button then hid. A click on the button itself has not been confirmed.

## Host behavior

- Private windows run no extensions.
- CRX signatures are not verified. Packages come over TLS from the store, or from a file the user chose.
- Store extensions check for updates about 30 seconds after launch. The check sends their identifiers and versions to Google. An update asking for new access needs approval, and a declined update is asked about again at the next launch.
- Enabling or adding an extension does not reach pages that are already open until they reload.
