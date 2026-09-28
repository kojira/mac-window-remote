# mac-window-remote

View and operate **one Mac window at a time** from an iPhone.

- A resident macOS menu bar app captures a single selected window (ScreenCaptureKit) and injects clicks/keys (CGEvent).
- The iPhone side is a web app (Safari / Home Screen) served by the Mac app, reachable only inside your Tailscale tailnet over HTTPS.
- Pinch-zoom and pan the window, tap to click, type with the iPhone keyboard (Japanese IME and dictation work, because only committed text is sent), send the iPhone clipboard text to the Mac, and send images that the Mac saves to a temporary file and hands back as a path.

## Status

**Design phase.** There is no implementation yet. The design is in `docs/DESIGN.md` (on the `design/initial` branch until merged).

## License

MIT, see [LICENSE](LICENSE).
