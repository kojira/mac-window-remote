# mac-window-remote — Design (v0.1, design phase)

Status: **proposed design, not yet implemented.** This file is the source of truth for
the implementation. If the implementation discovers a fact that contradicts this
document, stop the affected work, update this document first, then continue.

## 1. Goal and scope

From an iPhone, view and operate **one selected Mac window at a time** over a private
Tailscale network.

The user experience, end to end:

1. On the Mac, a menu bar app runs in the background. It needs Screen Recording and
   Accessibility permission, which a person grants once.
2. On the iPhone, the user opens a Tailscale HTTPS URL in Safari (or from a Home
   Screen icon). The page is paired with the Mac once, using a QR code or a pairing code.
3. The iPhone shows a list of the Mac's visible windows. The user taps one.
4. The window streams to the phone. The user pinches to zoom, pans with two fingers,
   taps to click, drags with one finger to scroll, and types with the iPhone keyboard.
   Japanese IME and dictation work because only committed text is sent to the Mac.
5. Later slices add: sending iPhone clipboard text to the Mac clipboard (optionally
   pasting it), sending an image that the Mac saves as a temp file and returns as a
   path, and a key bar with modifiers and user-defined key combos.

### Honest constraints (shown to users in the README and in the web UI where relevant)

- **The Mac must be unlocked and its display awake.** macOS does not render windows
  while the screen is locked, so nothing can be captured or operated.
  While a client is viewing, the app keeps the display from sleeping due to idle time
  (see D15). The user's own auto-lock and screen saver settings still apply.
- **Only windows that are on screen in the current Space can be picked.** Minimized
  windows, hidden apps, and windows in other Spaces are not listed.
- **Viewing does not move windows, but operating does.** Viewing an occluded window works
  because ScreenCaptureKit captures the window's own content. Any click, scroll, or key
  input first brings the target window to the front, because macOS delivers synthetic
  input to whatever is on screen at that point.
- **The Mac's pointer really moves.** Input goes through real mouse and keyboard events,
  so someone using the Mac at the same time will see the pointer move and focus change.
- **macOS asks again for Screen Recording.** On recent macOS versions a person at the Mac
  must periodically confirm that the app may keep recording the screen. This cannot be
  automated.

### Non-goals (explicitly out of scope)

- Audio streaming.
- Full-desktop or multi-monitor desktop view. Only one window is streamed. The window
  may be on any display.
- Operating a locked Mac, unlocking it, or waking a sleeping Mac.
- Minimized windows, other Spaces, and Mission Control or Space switching.
- Exposing the app outside the tailnet. Tailscale Funnel and port forwarding are
  explicitly unsupported.
- More than one connected client at a time.
- General file transfer or file sync. Images are sent only to get a path, and nothing is
  sent from the Mac to the iPhone.
- Sending the Mac clipboard to the iPhone.
- A native iOS app, App Store or Mac App Store distribution, and notarized binaries.
- H.264, WebRTC, or adaptive bitrate in the MVP. D3 describes the later path.
- Window thumbnails and app icons in the window list.
- Non-macOS hosts.

