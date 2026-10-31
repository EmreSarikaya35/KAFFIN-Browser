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
| Action popup            | Not tested   | Built on WebKit's popover, never opened |
| `notifications`, `downloads`, `identity`, `debugger` | Not in the SDK permission list | Expect these to fail |
| `offscreen`, `userScripts` | Unknown   | Requested by uBlock Origin Lite, behavior not checked |
| Safari app extensions   | Not built    | WebKit can load them; KAFFIN has no install path |

## Host behavior

- Private windows run no extensions.
- CRX signatures are not verified. Packages come over TLS from the store, or from a file the user chose.
- There is no update check, so installed extensions stay on their version.
- Enabling or adding an extension does not reach pages that are already open until they reload.
