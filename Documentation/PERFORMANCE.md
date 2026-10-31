# Performance

## Five sites, KAFFIN against Chrome (2026-11-01)

Apple M2, 16 GB, macOS 27.0.1, on battery while charging. KAFFIN Release build, Chrome 156 with a new empty profile and no extensions. One run of each.

Sites: wikipedia.org, developer.apple.com, bbc.com, github.com, news.ycombinator.com, one tab each, measured 28 seconds after opening.

| Measurement              | KAFFIN | Chrome |
| ------------------------ | ------ | ------ |
| Processes                | 8      | 13     |
| Memory, summed RSS       | 850 MB | 1903 MB |
| Idle CPU, over 30 seconds | 0.27%  | 5.7%   |

KAFFIN breakdown: app 116 MB, 5 WebContent 654 MB, Networking 41 MB, GPU 39 MB.

Limits of this result:

- It is a single run on live sites, whose content and ads change between loads.
- Summed RSS counts shared memory more than once, in both browsers, so these are not real totals.
- Both ran in the background without focus. Chrome's idle figure moved between 5.7% and 11.7% across two runs.
- It measures startup and idle only: no scrolling, video, long sessions, or the 10 to 50 tab scenarios.
- Energy use was not measured, because `powermetrics` needs administrator rights.

## Tab sleeping (2026-10-31)

Two heavy test pages and one audio page, in the sandboxed Release app:

| State                | WebContent processes | Memory |
| -------------------- | -------------------- | ------ |
| Before sleeping      | 3                    | 704 MB |
| Two tabs asleep      | 1                    | 29 MB  |
| One tab woken        | 2                    | 362 MB |

The pages allocate large arrays on purpose, so real sites will save less.

## Stability (2026-11-01)

Sandboxed Release app, on a small local page.

| Test | Result |
| ---- | ------ |
| Forced kill (`kill -9`) after 5 seconds, three times in a row | Each launch restored the earlier tabs. Integrity check passed, no foreign key violations |
| 300 tabs opened and closed in turn | App memory 37 MB to 42 MB. No WebContent process left over |
| 50 open tabs | All loaded, 50 WebContent processes, 1320 MB in total, app 66 MB, no crash report |

These cover tab churn and sudden termination. A multi-hour session on real sites has not been run.
