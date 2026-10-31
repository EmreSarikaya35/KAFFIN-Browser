import WebKit

/// WebKit has no public mute API, so this silences media elements through script.
// shortcut: reaches only the main frame's audio and video elements. Web Audio and media in iframes keep playing.
@MainActor
enum TabAudioMuter {
    private static let world = WKContentWorld.world(name: "KaffinAudio")

    /// Tracks what it muted, so unmuting never unmutes media the page muted itself.
    private static let script = """
    const mine = (window.__kaffinMutedMedia ??= new WeakSet());
    const silence = (media) => {
      if (!media.muted) {
        media.muted = true;
        mine.add(media);
      }
    };
    window.__kaffinIsMuted = muted;
    if (!window.__kaffinHooked) {
      window.__kaffinHooked = true;
      document.addEventListener('play', (event) => {
        if (window.__kaffinIsMuted) silence(event.target);
      }, true);
    }
    for (const media of document.querySelectorAll('audio, video')) {
      if (muted) {
        silence(media);
      } else if (mine.has(media)) {
        media.muted = false;
        mine.delete(media);
      }
    }
    """

    static func apply(muted: Bool, to webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(script, arguments: ["muted": muted], contentWorld: world)
    }
}
