# mac-window-remote

View and operate **one Mac window at a time** from an iPhone.

- A resident macOS menu bar app captures a single selected window (ScreenCaptureKit) and injects clicks/keys (CGEvent).
- The iPhone side is a web app (Safari / Home Screen) served by the Mac app, reachable only inside your Tailscale tailnet over HTTPS.
- The phone works like a trackpad: one finger moves the Mac pointer (drawn as an arrow on the phone), tap clicks at the pointer, a two-finger tap right-clicks, two fingers scroll, a long-press starts a drag (tap to release), pinch zooms, and three fingers pan the zoomed view. Type with the iPhone keyboard (Japanese IME and dictation work, because only committed text is sent).

## Status

**Slice 1 (MVP)**: pair → pick a window → view → zoom → click → scroll → type. Clipboard text, image upload, and the key bar are later slices. The design is in [`docs/DESIGN.md`](docs/DESIGN.md).

## Honest constraints

- The Mac must be unlocked and its display awake. While you are viewing, the app keeps the display from sleeping because of idle time.
- Only windows that are on screen in the current Space can be picked. Minimized windows, hidden apps, and other Spaces are not listed.
- Viewing does not move windows, but operating does. Any click, scroll, or typing first brings the window to the front.
- The Mac's pointer really moves.
- macOS periodically asks a person at the Mac to confirm Screen Recording again.

## Requirements

- macOS 14 or later, and Xcode with Swift 6.3 or later
- iOS 16.4 or later (Safari or a Home Screen web app)
- Tailscale on the Mac and the iPhone, in the same tailnet, with **MagicDNS** and **HTTPS Certificates** enabled in the admin console

## Build and run

```sh
scripts/build-app.sh
open build/MacWindowRemote.app
```

The script signs ad-hoc by default. With an ad-hoc signature, macOS may ask again for Screen Recording and Accessibility after each rebuild. To keep those grants, sign with your Apple Development certificate (a free Apple ID is enough):

```sh
security find-identity -v -p codesigning     # pick one
CODESIGN_IDENTITY="<name of the identity>" scripts/build-app.sh
```

Development: `MWR_WEB_ROOT=$PWD/web build/MacWindowRemote.app/Contents/MacOS/MacWindowRemote` serves the web client from disk, so client edits need only a reload.

Tests: `cd mac && swift test`, and `node --test tests/web/*.test.mjs` for the gesture recognizer.

## Setup

1. Open the app. **Setup & Permissions** opens by itself.
2. Grant **Screen Recording**: click Request or Open Settings, and turn the app on. Then click **Relaunch**.
3. Grant **Accessibility** the same way.
4. In Terminal, run the command that Setup shows, once: `tailscale serve --bg http://127.0.0.1:8765`
5. Enter the `https://…` address that `tailscale serve` prints as the **iPhone URL** in Setup or Settings.
6. Menu bar → **Pair iPhone…**, and scan the QR code with the iPhone camera. Safari opens the window list.
   To use it from the Home Screen, choose Share → **Add to Home Screen**, open the icon, and paste the pairing code shown under the QR code.
7. Keep the Mac unlocked while you use it remotely.

The server listens on `127.0.0.1` only. It is reachable from the tailnet only through `tailscale serve`, and every function needs the pairing secret. **Reset pairing…** in the menu revokes the old secret. The secret is stored in `~/Library/Application Support/mac-window-remote/pairing-secret` (readable only by your user); the app does not use the Keychain. If you used an earlier build that kept the secret in the Keychain, pair the iPhone again once. The old Keychain item "mac-window-remote" is no longer read and can be deleted in Keychain Access.

## License

MIT, see [LICENSE](LICENSE).
