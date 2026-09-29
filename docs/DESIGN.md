# mac-window-remote — Design (v0.2)

Status: **Slice 1 implemented, then replaced by revision 2 (§11: WebRTC video and
trackpad-style input), which is implemented and awaits acceptance on a real iPhone.
§12 (D32) replaces pairing with the Mac owner's Tailscale identity. §13 (D33) replaces the
viewer's top bar with a bottom bar that has quick-switch slots. §14 (D34) replaces the
D13 key bar with a key panel.** Sections marked *Superseded by §11* describe
slice 1 behavior that revision 2 removes. This file is the source of truth for the
implementation. If the implementation discovers a fact that contradicts this
document, stop the affected work, update this document first, then continue.

## 1. Goal and scope

From an iPhone, view and operate **one selected Mac window at a time** over a private
Tailscale network.

The user experience, end to end:

1. On the Mac, a menu bar app runs in the background. It needs Screen Recording and
   Accessibility permission, which a person grants once.
2. On the iPhone, the user opens a Tailscale HTTPS URL in Safari (or from a Home
   Screen icon). *(§12 D32: no pairing; the iPhone must be signed in to Tailscale as the
   Mac's owner.)*
3. The iPhone shows a list of the Mac's visible windows. The user taps one.
4. The window streams to the phone. The user pinches to zoom, pans with two fingers,
   taps to click, drags with one finger to scroll, and types with the iPhone keyboard.
   Japanese IME and dictation work because only committed text is sent to the Mac.
   *Revision 2 (§11) changes the gestures to a trackpad model: one finger moves the
   Mac cursor relatively, two fingers scroll, three fingers pan, and the video arrives
   over WebRTC so it also works well on mobile networks.*
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
- ~~H.264, WebRTC, or adaptive bitrate in the MVP.~~ Revision 2 (§11) adds all three,
  because the user often connects over mobile networks.
- Window thumbnails and app icons in the window list.
- Non-macOS hosts.

## 2. Key decisions

### D1. One process on the Mac, one static web client
- **Mac:** a single Swift app, `MacWindowRemote.app`, running as a menu bar agent
  (`LSUIElement = YES`) with no Dock icon. It contains the HTTP/WebSocket server,
  capture, input injection, clipboard, and uploads. It has no helper processes and no
  daemons.
- **iPhone:** a static web app (HTML + CSS + vanilla ES modules, **no build step and no
  framework**) served by the Mac app. It includes a minimal `manifest.webmanifest` and
  `apple-mobile-web-app-capable` meta so it can be added to the Home Screen.
- **Why:** this is the fewest moving parts. Swift is needed for ScreenCaptureKit and
  CGEvent. A no-build web client can be edited and reloaded without extra tooling.
- **Minimum versions:** macOS 14 Sonoma or later (for `SCContentFilter.pointPixelScale`,
  `SCStreamConfiguration.ignoreShadowsSingleWindow`, and Hummingbird 2). iOS 16.4 or
  later, using Safari or a Home Screen web app.

### D2. Server stack and binding
- The server uses **Hummingbird 2** with **HummingbirdWebSocket** through SwiftPM. It
  serves static files and one WebSocket endpoint on one port.
- It binds to **`127.0.0.1` only**. The default port is `8765`, and the port can be
  changed in Settings. Changing the port restarts the listener.
- Only `tailscale serve` (D5) and local processes can reach the server. It never binds to
  `0.0.0.0` or to a tailnet or LAN interface.
- Routes:
  - `GET /`, `/app.js`, `/*.js`, `/style.css`, `/manifest.webmanifest`, `/icon-*.png`:
    static files, served without authentication. They contain no secrets.
  - `GET /ws`: WebSocket. The first message must be `auth` (D6). **All functionality
    goes over this socket**, including image upload, so only one channel needs
    authentication.
  - *Amended by §12 D32:* every request, static files included, must carry the owner's
    `Tailscale-User-Login`; there is no `auth` message.

### D3. Transport for the MVP: JPEG frames over WebSocket with ack-based flow control
> *Superseded by §11 D20–D22.* The JPEG pipeline and `frame.ack` are removed once the
> WebRTC video track works; there is no dual path.
- The server sends binary WebSocket messages with the framing in §4.1. Each message
  holds a JSON header and one **complete JPEG** of the window. There are no diff tiles.
- **Frame source:** `SCStream` with `SCContentFilter(desktopIndependentWindow:)`.
  - `showsCursor = true`, `ignoreShadowsSingleWindow = true`.
  - `minimumFrameInterval = 1/15 s`, `queueDepth = 5`, pixel format BGRA.
  - Frames whose `SCStreamFrameInfo.status` is not `.complete` are skipped. This covers
    idle frames, where the window has not changed, so a static window costs no
    bandwidth.
- **Encoding:** `VTCreateCGImageFromCVPixelBuffer` to `CGImageDestination` (JPEG, quality
  0.7) on a serial encode queue.
- **Flow control:** at most **one frame is in flight**. After sending frame N, the server
  waits for `frame.ack {frameId: N}`. While it waits, it keeps only the newest complete
  `CMSampleBuffer`, holding one reference and replacing it when a newer one arrives.
  When the ack arrives, it encodes and sends that buffer. As a result, a slow network
  lowers the frame rate rather than adding latency.
- **Why JPEG:** trivial on both ends. `createImageBitmap` decodes in Safari. The MVP is
  a single window at 15 fps or less on a tailnet, so bandwidth of about 1–5 Mbit/s
  while the window changes is acceptable. There are no codec or WebCodecs compatibility
  risks for the first slice.
- **Later path (not in this design's slices):** H.264 via VideoToolbox
  (`VTCompressionSession`, low-latency, Annex B), decoded in the browser with WebCodecs
  `VideoDecoder`. It would use the same WebSocket and the same header framing with
  `t: "video"`. The ack-based flow control would be replaced by keyframe requests.
  WebRTC is not planned, because inside a tailnet it adds signaling and ICE complexity
  with no benefit.

### D4. Capture resolution and Retina
> *Amended by §11 D21:* pixel format, output-size alignment, and the resize path change
> for the H.264 encoder. The 2560 px cap and the 500 ms bounds poll stay.
- The output size in pixels is the window size in points × `filter.pointPixelScale`.
  For example, a window on a Retina display has scale 2.
- The long edge is capped at **2560 px**, scaling both axes proportionally. This keeps
  text sharp when pinch-zoomed on a phone and bounds JPEG size.
- The window's bounds are polled every **500 ms** using `CGWindowListCopyWindowInfo`
  (`kCGWindowListOptionIncludingWindow`, window id). If the size changes by 1 pt or more,
  the server calls `stream.updateConfiguration` with the new output size. If the window
  id disappears from the list, the server sends `view.state window_gone` and stops the
  stream.

### D5. HTTPS via `tailscale serve` (secure context), with a clipboard fallback
- iOS Safari exposes `navigator.clipboard.readText()` only in a secure context, and only
  in response to a user gesture. The app therefore relies on **`tailscale serve`**, which
  terminates HTTPS with a valid `*.ts.net` certificate and proxies to
  `http://127.0.0.1:8765`. WebSocket proxying works through it.
- The user runs a command once. The app shows it with a Copy button and does not run it:
  `tailscale serve --bg http://127.0.0.1:8765`
- The page URL becomes `https://<your-mac>.<tailnet>.ts.net/`.
- The Mac app does **not** call Tailscale APIs or CLIs. The user enters the base URL once
  in Settings ("iPhone URL"). The app uses it only to build the pairing QR code.
- **Clipboard fallback:** if `readText()` rejects or is unavailable, a sheet with a
  textarea opens. The user long-presses and chooses Paste, then taps Send. This is also
  the path when the page is opened over plain HTTP.
- `tailscale serve` exposes the page to every device in the tailnet. The pairing secret
  (D6) is what restricts who can use it.
- *Amended by §12 D32:* the Mac app runs `tailscale status --json` to learn its owner's
  login, and the "iPhone URL" setting and pairing QR code are removed. The Tailscale
  identity header restricts who can use the page.

### D6. Authentication: a single pairing secret
> *Superseded by §12 D32.* There is no pairing secret, pairing code, QR code, Keychain
> item, or secret file any more; the Mac admits only its owner's Tailscale login. The
> text below records the slice 1 design.
- On first launch the Mac app generates **32 random bytes** (`SecRandomCopyBytes`),
  encoded as base64url. This is the pairing secret. It is stored in the **Keychain**
  (generic password, service `mac-window-remote`). It is never written to logs.
  *(A short-lived amendment moved it to an owner-only file before D32 removed it.)*
- **Pair iPhone… window (menu bar):**
  - A QR code of `<iPhone URL>/#pair=<secret>`.
  - The same secret as a copyable "pairing code".
  - A note if the iPhone URL is not set.
- **Web client pairing:**
  - If `location.hash` contains `pair=`, the client stores the secret in `localStorage`
    (`mwr.secret`) and removes the fragment with `history.replaceState`. The fragment is
    never sent to the server and never appears in proxy logs.
  - If no secret is stored, the client shows the Pair screen with a text field for the
    pairing code. This matters because a Home Screen web app has separate storage from
    Safari, so a user who adds the page to the Home Screen after pairing in Safari pastes
    the code once more.
- **WebSocket authentication:**
  - The first client message must be `{"t":"auth","secret":…}` within 5 s.
  - The server compares it in constant time.
  - If it matches, the server replies with `hello`.
  - Otherwise the server closes with code **4001** (`auth_failed`). The client then
    clears the stored secret and shows the Pair screen with "Pairing code was rejected.
    Pair again from the Mac menu."
- **Reset pairing** (menu bar) generates a new secret and closes any open session with
  4001.
- **Single client:** a newly authenticated connection replaces the current one. The old
  one is closed with **4002** (`replaced`) and shows "Opened on another device/tab".
- No rate limiting and no Origin checks. The secret has 256 bits, the server is reachable
  only through the tailnet, and nothing else carries authority.

### D7. Coordinate mapping (touch → image → window points → global points)
> *Superseded by §11 D24.* The server owns the cursor position; the client sends
> relative deltas, so frame headers, `frameId` lookup, and `stale_coordinates` go away.
- **Frame header** (§4.1) carries:
  - `frameId`, `windowId`
  - `width`, `height`: image size in px
  - `content: {x, y, w, h}`: the window's content rect inside the image, in px. This is
    derived from `SCStreamFrameInfo.contentRect × contentScale` and equals the full image
    except briefly during a resize.
  - `window: {x, y, w, h}`: the window's global frame in **points** at capture time. The
    origin is top-left, using the CG global display coordinates that CGEvent also uses.
- **Client:**
  1. The client draws the image on a `<canvas>` with a CSS transform for zoom and pan.
  2. For a touch, it inverts the transform to get image px `(ix, iy)`.
  3. It normalizes against the content rect: `u = (ix − content.x)/content.w`,
     `v = (iy − content.y)/content.h`.
  4. If `u` or `v` is outside [0, 1], it ignores the touch (no click).
  5. It sends `{u, v, frameId}`.
- **Server:**
  1. The server keeps the headers of the last 16 frames sent.
  2. It looks up `frameId`. If the id is unknown, it uses the latest frame.
  3. It computes `p = currentOrigin + (u × frame.window.w, v × frame.window.h)`, where
     `currentOrigin` is the window's bounds origin **queried right now**, so a moved
     window still gets the right point.
  4. The size comes from the frame the user saw, because after a resize the content is
     normally anchored top-left.
  5. If `p` is outside the current bounds, the input is rejected with error
     `stale_coordinates` and nothing is clicked.
- Retina scale never reaches the client, because normalized coordinates hide it.
- Scroll deltas are converted the same way. The client sends deltas in content-normalized
  units, `du` and `dv`, and the server multiplies them by `frame.window.w/h` to get
  points.

### D8. Focusing the target window
> *Superseded by §11 D25* (focus once per target, never wait per input). Steps 1–3 below
> are reused; the per-input 300 ms wait is removed.

Before every input (pointer, scroll, text, key, paste), the input actor does the
following:
1. **Is the window already frontmost?** It checks the first layer-0 on-screen window in
   `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`. If that has the target `windowId`,
   the rest of this list is skipped.
2. **Activate the owning app:** `NSRunningApplication(processIdentifier: pid).activate()`.
3. **Raise the window through Accessibility:**
   - The app gets `AXUIElementCreateApplication(pid)` and reads `kAXWindowsAttribute`.
   - It picks the AX window whose `AXPosition` and `AXSize` equal the CG bounds (within
     1 pt). Among several matches, it prefers the one whose `AXTitle` equals the CG
     window name.
   - It performs `kAXRaiseAction` and sets `kAXMainAttribute = true`.
   - If nothing matches, activating the app is the best effort.
   - **No private APIs** (such as `_AXUIElementGetWindow`).
4. **Wait for the result:** it polls step 1 every 20 ms, up to **300 ms**, then posts the
   input anyway.

### D9. Input injection with CGEvent
- Events come from `CGEventSource(stateID: .hidSystemState)` and are posted to
  `.cghidEventTap`.
- All input is processed **in order** on one serial input actor.
  *Amended by §11 D25:* cursor moves and scrolls are coalesced (latest wins) and never
  wait behind focus.
- **Click:** `mouseMoved` to `p`, then `leftMouseDown` and `leftMouseUp` with
  `mouseEventClickState = n`. A double-click is two down/up pairs with click state 1
  and then 2.
- **Right-click:** `rightMouseDown` and `rightMouseUp`.
- **Drag:** `leftMouseDown` at the start, `leftMouseDragged` for each move, and
  `leftMouseUp` at the end. If the socket closes during a drag, the server posts
  `leftMouseUp` at the last point, so a button is never left stuck.
- **Scroll:** move the pointer to `p`, then post
  `CGEvent(scrollWheelEvent2Source:units:.pixel, wheelCount:2, …)` with the point deltas.
  The direction is "natural": content follows the finger.
- **Text (committed Unicode):**
  - Text is split into grapheme-cluster-safe chunks of **≤ 20 UTF-16 units** (the CGEvent
    Unicode string limit).
  - Each chunk is a keyDown/keyUp pair with `keyboardSetUnicodeString` and virtual key 0,
    with modifier flags cleared.
  - `\n` is sent as a Return key and `\t` as a Tab key.
  - **IME safety:** a Mac input method, such as Japanese kana mode, could reinterpret
    these events. Before typing, the injector saves `TISCopyCurrentKeyboardInputSource()`,
    selects `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()`, types, and then
    restores the saved source. Text therefore never goes through the Mac IME.
- **Special keys and combos:**
  - Named keys map to `kVK_*` virtual key codes (table in §4.3), using ANSI positions for
    letters, digits, and punctuation.
  - A combo is modifier keyDowns (`kVK_Command`/`Control`/`Option`/`Shift`, with
    cumulative flags), then the key down/up with flags, then modifier keyUps in reverse.

### D10. iPhone text input: compose on the phone, send on Return
- The input bar has a normal `<input type="text">` field, with autocorrect and
  autocapitalize off. The user types, uses Japanese IME conversion, or dictates entirely
  **on the phone**. Nothing is sent while the text is being composed.
- **Return** (the `keydown` Enter with `isComposing == false`):
  - If the field is non-empty: send `text` with the field's value, then clear the field.
    This sends the text only, without Enter.
  - If the field is empty: send `key Enter`.
- **Backspace in an empty field** (`beforeinput` `deleteContentBackward` on an empty
  value) sends `key Backspace`.
- **Why:** it is deterministic with IME candidates, predictive text, and dictation
  revisions, which all edit the field before commit. Streaming every keystroke would
  break them.

### D11. Clipboard text (slice 2)
- The **Clipboard** button calls `navigator.clipboard.readText()` inside the tap handler.
  On failure it opens the fallback textarea sheet (D5).
- The sheet and preview show the first 200 characters and have two actions:
  **Copy to Mac** (`paste: false`) and **Paste into window** (`paste: true`).
- On the Mac, the app calls `NSPasteboard.general.clearContents()` and
  `setString(_, forType: .string)`. If `paste` is true, it focuses the window (D8) and
  sends ⌘V.
- The previous Mac clipboard is **not** restored, because the user asked to put the text
  there.
- The maximum is 1 MiB of UTF-8. Larger text is rejected with `too_large`.

### D12. Image → temp file → path (slice 3)
- The **Image** button opens `<input type="file" accept="image/*">`. iOS offers the photo
  library, the camera, and Files. iOS normally converts HEIC to JPEG for web uploads, and
  whatever arrives is stored as-is.
- The image is uploaded as one binary WebSocket message (§4.1) with header
  `{t:"image", id, action}`, where `action` is `clipboard` (the default), `type`, or
  `none`.
- **Limits:**
  - At most **25 MiB** per image. The server's maximum WebSocket frame size is 26 MiB.
  - The type is sniffed from the magic bytes. PNG, JPEG, HEIC/HEIF, GIF, and WebP are
    accepted. Anything else is rejected with `unsupported_type`.
- **Location:** `FileManager.default.temporaryDirectory/mac-window-remote/uploads/`. This
  is under the per-user `$TMPDIR` (`/var/folders/…`), which only this user can read.
  The directory is created with mode 0700.
- **Name:** `img-YYYYMMDD-HHMMSS-<4 hex>.<ext>`. The name has no spaces, so the path
  never needs quoting.
- **Action:**
  - `clipboard`: the path is put on the Mac clipboard as a string.
  - `type`: the window is focused (D8) and the path is typed (D9).
  - `none`: nothing more happens.
  In all cases the server replies with `result {path}`, and the phone shows the path
  with a toast "Saved: …/img-…png (copied on Mac)".
- **Cleanup:** at app launch and then every hour, the app deletes files in that
  directory older than **24 h**. It deletes nothing outside it. The "Open uploads
  folder" menu item reveals the directory in Finder.

### D13. Key bar and custom buttons (slice 4)
> *The key bar layout is superseded by §14 D34 (a 2×6 key panel). The one-shot and lock
> modifier rules below carry over. Custom buttons remain a later slice.*
- The key bar is a horizontally scrollable row above the text field. Defaults:
  `Esc  Tab  ←  ↑  ↓  →  ⏎  ⌫  ⌃  ⌥  ⌘  ⇧`, then the user's custom buttons, then `＋`.
- **Modifiers are one-shot:**
  - Tapping ⌃⌥⌘⇧ arms the modifier, and it is highlighted.
  - The next key-bar key, or the next committed text of **exactly one character** from
    `[a-z0-9]` or the ANSI punctuation in §4.3, is sent as `key` with the armed
    modifiers. Then the modifiers are disarmed.
  - Any other text is sent as plain `text`, and the modifiers are disarmed.
  - A long press on a modifier locks it until tapped again.
- **Custom buttons:**
  - Each button is `{label, key, mods[]}`, stored in the phone's `localStorage`
    (`mwr.buttons`). They are not synced to the Mac.
  - `＋` opens a small form: a label, a key picker (keys in §4.3), and modifier
    checkboxes.
  - Long-pressing a custom button offers Edit and Delete.
- **Pointer extras** are also in this slice: long-press and release is a right-click, and
  long-press then move is a left-button drag (D14).

### D14. Viewer gestures (the canvas uses `touch-action: none`, so all gestures are custom)
> *Superseded by §11 D23.* One-finger scroll, double-tap, absolute tap-to-point, and
> the slice 4 long-press rows are replaced by the trackpad model.
| Gesture | Effect | Slice |
|---|---|---|
| 2-finger pinch / pan | Zoom (1× = fit to screen, up to 8×) and pan the view on the phone only | 1 |
| 1-finger tap | Left click at the point | 1 |
| 2nd tap within 300 ms and 20 px | Double-click (sent as `pointer doubleClick`) | 1 |
| 1-finger drag, starting before 400 ms | Scroll the window (`scroll`, throttled to one message per animation frame) | 1 |
| 1-finger hold 400 ms, then release without moving | Right-click | 4 |
| 1-finger hold 400 ms, then move | Left-button drag (`pointer down/move/up`) | 4 |

A tap moves at most 10 px and lasts at most 400 ms. The Fit button resets zoom and pan.

### D15. Frames stop when nobody is watching
- Capture runs only between `view.start` and `view.stop` or disconnect, and only for the
  one selected window.
- When the page becomes hidden (`visibilitychange`), for example because the phone is
  locked or Safari is in the background, the client closes the socket. It reconnects
  when the page is visible again.
- While capture runs, the app holds an `IOPMAssertion` of type
  `PreventUserIdleDisplaySleep`, named "mac-window-remote viewing". It releases the
  assertion when capture stops.

### D16. Permissions onboarding
- **At launch**, the app checks `CGPreflightScreenCaptureAccess()` and
  `AXIsProcessTrusted()`. The menu bar icon shows a warning badge while either is
  missing.
- **Setup & Permissions window.** It opens automatically on first launch or when a
  permission is missing. It has two rows, each with a status (✅/⚠️) and two buttons:
  - **Screen Recording:**
    - "Request" calls `CGRequestScreenCaptureAccess()`.
    - "Open Settings" opens
      `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
    - After the permission is granted, the app shows "Relaunch required" with a
      **Relaunch** button, because macOS applies the grant only after a relaunch.
  - **Accessibility:**
    - "Request" calls `AXIsProcessTrustedWithOptions` with the prompt option.
    - "Open Settings" opens `…?Privacy_Accessibility`.
    - Status is re-polled every 2 s while the window is open.
  - The same window shows the `tailscale serve` command, the iPhone URL field, and a
    link to Pair. *(§12 D32: the allowed login field replaces the iPhone URL and Pair.)*
- **Web client:** `hello.permissions` reports both permissions.
  - Missing screen recording: the window list is replaced by "Screen Recording permission
    is missing on the Mac. Open the Mac menu bar app → Setup."
  - Missing accessibility: the viewer works, and input actions show a toast "Mac needs
    Accessibility permission to control windows."

### D17. Build, signing, and run
- **Repo layout:**
  ```
  mac/Package.swift                    SwiftPM, macOS 14, deps: hummingbird, hummingbird-websocket
  mac/Sources/MacWindowRemote/         app sources (see §5)
  mac/Tests/MacWindowRemoteTests/      unit tests (see §7)
  mac/Resources/Info.plist             LSUIElement, bundle id, usage strings
  web/                                 index.html, app.js (+ modules), style.css, manifest, icons
  scripts/build-app.sh                 swift build -c release → build/MacWindowRemote.app
  ```
- `scripts/build-app.sh` does the following:
  1. It builds in release mode.
  2. It assembles `build/MacWindowRemote.app`, copying the binary, `Info.plist`, and
     `web/` to `Contents/Resources/web`.
  3. It signs the app with `codesign --force --sign "${CODESIGN_IDENTITY:--}"`.
- **Signing and permissions:**
  - With the ad-hoc default (`-`), macOS ties the permission grants to the exact binary,
    so **each rebuild may require granting Screen Recording and Accessibility again.**
  - The README recommends setting `CODESIGN_IDENTITY` to an Apple Development certificate
    (a free Apple ID is enough) so grants survive rebuilds.
- **Run:** `open build/MacWindowRemote.app`.
- **Development:** setting the environment variable `MWR_WEB_ROOT=<repo>/web` makes the
  server read web files from disk, so client edits need only a reload.
- **Launch at login:** a toggle in Settings using `SMAppService.mainApp`.
- **No CI** in these slices. Unit tests run with `swift test` in `mac/`.

### D18. Reconnect and failure behavior
> *Amended by §11 D22/D27:* the viewer also tracks the WebRTC connection state; see D27
> for media failures. Signaling reconnect is unchanged.
The client state machine:

```
Unpaired ──code/QR──▶ Connecting ──hello──▶ WindowList ──tap──▶ Viewing
   ▲                     │  ▲                     ▲               │
   └──── close 4001 ─────┘  └── backoff ◀── socket closed/timeout ┘
                                                     (resume last window)
```
- **Reconnect:**
  - Backoff is 0.5 s, 1 s, 2 s, then 5 s maximum. It resets after `hello`.
  - While reconnecting, the viewer keeps the last frame, dimmed, with "Reconnecting…".
  - The selected `windowId` is kept in `sessionStorage`. After reconnect, the client sends
    `view.start` for it again. If the reply is `window_gone`, the client returns to the
    list with the toast "Window closed".
- **Liveness:**
  - The server sends a WebSocket ping every 10 s.
  - The client treats 15 s without any message as dead. This is safe because pings arrive
    as control frames, and during idle viewing the server sends
    `{t:"ping"}` text every 10 s too.
  - The client then closes and reconnects.
- **Server-side failures:**
  | Condition | Server behavior | Client shows |
  |---|---|---|
  | Screen Recording missing | `view.state capture_unavailable reason=permission_screen_recording` | Permission message (D16) |
  | `SCStream` stops with error (e.g. screen locked, display sleep) | `view.state capture_unavailable reason=stream_stopped`; retry `view.start` automatically every 5 s while the client stays in the viewer | "Mac screen unavailable (locked or asleep?) — retrying" |
  | Window closed / id vanished | `view.state window_gone` | Back to list + toast |
  | Accessibility missing on input | `error permission_accessibility` | Toast (D16) |
  | Input outside current window | `error stale_coordinates` | Nothing (silent) |
  | Bad or oversized message | `error bad_request` / `too_large` | Toast |
- A new `view.start` while already viewing stops the old stream first.
- A disconnect stops capture, releases a held mouse button (D9), and releases the display
  assertion (D15).

### D19. Mac menu bar UX
- **Icon:** SF Symbol `rectangle.on.rectangle`. It is filled while a client is viewing,
  so a person at the Mac can see that the screen is being watched. It shows a warning
  badge while a permission is missing.
- **Menu:** *(§12 D32 removes Pair iPhone… and Reset pairing…, adds "Allowed: <login>",
  and replaces the iPhone URL setting with the allowed login override.)*
  - Status line: "Idle", "Connected", "Viewing: <App> — <Title>", or "Permissions
    needed"
  - Pair iPhone…
  - Setup & Permissions…
  - Settings… (port, iPhone URL, launch at login)
  - Open uploads folder
  - Reset pairing…
  - Quit
- **Logs:** `os.Logger` (subsystem `mac-window-remote`). Logs contain connections, errors,
  and window ids only. They **never contain the secret, typed text, clipboard content, or
  image data.**

## 3. iPhone screens

1. **Pair.** "Scan the QR in the Mac menu bar → Pair iPhone…, or paste the pairing code."
   It has a code field and a **Pair** button, and appears only when no secret is stored.
   *(Replaced by §12 D32: a **Not allowed** screen, shown on close 4001.)*
2. **Windows.**
   - A top bar with the title "Windows", a connection dot, and a Refresh button.
   - Pull-to-refresh is not required.
   - A list of rows: the **App name** in bold and the window title below it (or
     "(untitled)"), sorted by app and then by title. There are no thumbnails.
   - The list excludes this app's own windows and windows smaller than 50×50 pt.
   - An empty state: "No windows on screen (minimized windows and other Spaces are not
     shown)."
3. **Viewer.**
   - **Top bar** (auto-hides after 3 s, and tapping the top edge shows it): ‹ Windows,
     title (App — Title), a **Fit** button, and a connection dot. *(Replaced by §13 D33:
     no top bar; ‹, quick-switch slots, and Fit are in the bottom bar.)*
   - **Canvas:** the rest of the screen, black letterbox, with the gestures in D14.
   - **Bottom bar,** always visible and moving above the keyboard using
     `visualViewport`:
     - Slice 1: ⌨︎, which focuses the text field and brings up the iOS keyboard. With the
       keyboard up, the text field is visible and Return sends (D10).
     - Slice 2: 📋 Clipboard.
     - Slice 3: 🖼 Image.
     - Slice 4: the key bar row (D13).
   - **Overlays:** "Reconnecting…", "Mac screen unavailable…", and permission messages.
4. **Sheets:** the clipboard fallback textarea (D5/D11), the custom-button form (D13), and
   toasts for results and errors.

## 4. Protocol

### 4.1 Binary framing
A binary WebSocket message contains:

`[uint32 big-endian headerLength][header: UTF-8 JSON, headerLength bytes][payload bytes]`

- Server → client: `header.t = "frame"`, and the payload is JPEG.
- Client → server: `header.t = "image"`, and the payload is image bytes.

Text WebSocket messages are single JSON objects with a `t` field. The optional `id`, a
client-chosen string, is echoed in `result` and `error`.

### 4.2 Messages
Client → server:
```jsonc
{"t":"auth","secret":"<base64url>","client":"web/0.1"}
{"t":"windows.list"}
{"t":"view.start","windowId":1234}
{"t":"view.stop"}
{"t":"frame.ack","frameId":57}
{"t":"pointer","action":"click|doubleClick|rightClick|down|move|up","u":0.42,"v":0.13,"frameId":57}
{"t":"scroll","u":0.5,"v":0.5,"du":0.0,"dv":-0.03,"frameId":57}
{"t":"text","text":"こんにちは"}
{"t":"key","key":"Enter","mods":["cmd","shift"]}
{"t":"clipboard.set","id":"c1","text":"…","paste":false}
// binary: header {"t":"image","id":"i1","action":"clipboard|type|none"} + bytes
```
Server → client:
```jsonc
{"t":"hello","server":"0.1","permissions":{"screenRecording":true,"accessibility":true}}
{"t":"windows","items":[{"id":1234,"pid":501,"app":"Safari","title":"Docs","w":1280,"h":800}]}
{"t":"view.state","windowId":1234,"state":"starting|streaming|window_gone|capture_unavailable|stopped","reason":"…"}
// binary: header {"t":"frame","frameId":57,"windowId":1234,"width":2560,"height":1600,
//                 "content":{"x":0,"y":0,"w":2560,"h":1600},
//                 "window":{"x":100,"y":80,"w":1280,"h":800}} + JPEG
{"t":"result","id":"i1","ok":true,"path":"/var/folders/…/mac-window-remote/uploads/img-….png"}
{"t":"error","id":"c1","code":"too_large","message":"…"}
{"t":"ping"}
```
Close codes: `4001` auth_failed, `4002` replaced, `4003` protocol_error (first message not
auth, or auth timeout). *(§12 D32: there is no `auth` message; `4001` is `not_allowed`,
and `4003` is no longer used.)*

Error codes: `bad_request`, `too_large`, `unsupported_type`, `window_not_found`,
`stale_coordinates`, `permission_screen_recording`, `permission_accessibility`,
`internal`.

`pointer`, `scroll`, `text`, and `key` produce no `result` on success, which keeps
latency low. They produce an `error` on failure. `clipboard.set` and `image` always
produce a `result` or an `error`.

### 4.3 Key names
- `Enter, Tab, Escape, Backspace, Delete (forward), Space, ArrowLeft, ArrowRight,
  ArrowUp, ArrowDown, Home, End, PageUp, PageDown, F1–F12`
- `a–z, 0–9`
- `` - = [ ] \ ; ' , . / ` ``, using ANSI virtual key positions
- Mods: `ctrl, opt, cmd, shift`

Unknown key names are rejected with `bad_request`.

## 5. Mac source components (`mac/Sources/MacWindowRemote/`)
| File | Responsibility |
|---|---|
| `App.swift` | `@main`, `MenuBarExtra`, windows for Pair / Setup / Settings |
| `Settings.swift` | UserDefaults (port, iPhone URL), `SMAppService` toggle |
| `TailscaleIdentity.swift` | owner login from `tailscale status --json` (cached, Settings override), header check (§12 D32) |
| `Permissions.swift` | preflight/request/open-settings/relaunch |
| `Server.swift` | Hummingbird app: static files (bundle or `MWR_WEB_ROOT`), `/ws` |
| `Session.swift` | one active client, auth, message decode/dispatch, replace logic, pings |
| `Protocol.swift` | Codable messages, binary framing encode/decode |
| `WindowCatalog.swift` | `SCShareableContent` listing + filtering, CG bounds lookup |
| `CaptureSession.swift` | `SCStream`, resize polling, JPEG encode, ack flow control, frame header ring |
| `CoordinateMapper.swift` | pure mapping of (u, v, frame header, current bounds) to a global point or reject |
| `WindowFocuser.swift` | frontmost check, activate, AX raise/main |
| `InputInjector.swift` | CGEvent mouse/scroll/text/key, input-source switch, stuck-button release |
| `KeyMap.swift` | key name to `kVK_*` table |
| `Clipboard.swift` | NSPasteboard set + ⌘V |
| `UploadStore.swift` | sniff, size check, save, cleanup timer |
| `DisplayAssertion.swift` | IOPMAssertion hold/release |

The web client (`web/`) contains `index.html`, `style.css`, `app.js` (state machine,
socket), `viewer.js` (canvas, transform, gestures), `input.js` (text field, key bar,
custom buttons), and `manifest.webmanifest`.

## 6. Slices and acceptance criteria
All acceptance checks run on a real iPhone (Safari) against a real Mac through
`tailscale serve`, unless marked *unit*.

### Slice 1 — MVP: pair → pick window → view → zoom → click → type
1. After a clean install, the Setup window guides the user through granting both
   permissions, including the relaunch. The menu then shows "Idle" with no badge.
2. The pairing QR code opens the page in Safari, which lands on the Windows list. A
   wrong pairing code shows the rejection message. With a Home Screen web app, the user
   can pair by pasting the code.
3. The list shows on-screen windows as "App — Title". Minimized windows do not appear.
4. When the user taps a window, the image appears within 2 s. When the window's content
   changes on the Mac, the phone updates. A static window produces no frames: checking
   the server log shows no frames sent for 10 s of idleness.
5. Pinch zoom up to 8× shows sharp text on a Retina Mac. Two-finger pan works. Fit
   resets zoom and pan.
6. Tapping a button or link in the window (zoomed, and after the window was moved on the
   Mac) clicks exactly that element. The window comes to the front if it was behind.
   Double-tapping a word in a text editor selects it.
7. One-finger drag scrolls a web page or document in the window.
8. The user taps ⌨︎, types Japanese with the iPhone IME (for example, converting
   "にほんご" to "日本語"), and presses Return. "日本語" appears in the focused text field
   on the Mac. This holds **both with the Mac input source set to ABC and with it set to
   Japanese kana mode.** Afterwards, the Mac input source is the same as before.
9. Dictating a sentence and pressing Return inserts exactly the dictated text. Return
   with an empty field sends Enter. Backspace with an empty field deletes one character
   on the Mac.
10. Reconnect: turning Wi-Fi off and on again on the phone, or locking and unlocking it,
    returns to the same window automatically with "Reconnecting…" shown in between.
    Closing the window on the Mac returns the phone to the list with "Window closed".
11. Opening the page in a second tab or device closes the first with "Opened on another
    device/tab".
12. *Unit:*
    - `CoordinateMapper`: identity, Retina scale, content letterbox, moved window,
      resized window, out-of-bounds reject.
    - Protocol binary framing round-trip.
    - Text chunking: emoji or ZWJ sequences and combining marks are never split, and
      chunks are ≤ 20 UTF-16 units.
    - `PairingSecret` compare.
    - Auth: a wrong or late first message closes with 4001/4003.

### Slice 2 — Clipboard text
1. After copying text on the iPhone, tapping 📋 and then allowing the iOS "Paste" prompt
   shows a preview. **Copy to Mac** puts the text on the Mac clipboard, and ⌘V on the
   Mac pastes the same text, including newlines and Japanese.
2. **Paste into window** pastes it into the viewed window's focused field.
3. When `readText` is denied, the fallback textarea sheet appears, and pasting there and
   sending works the same way.
4. Text over 1 MiB shows a "too large" toast, and the Mac clipboard is unchanged.

### Slice 3 — Image → temp path
1. When the user picks a photo, the toast shows the path, and the Mac clipboard contains
   exactly that path. The file exists under `$TMPDIR/mac-window-remote/uploads/` and
   opens as an image.
2. With the action "type", the path is typed into the focused field of the viewed window.
3. A 30 MiB file is rejected with a "too large" toast. A non-image file is rejected with
   `unsupported_type`. Neither leaves a file behind.
4. *Unit:* magic-byte sniffing for each accepted type, name format, and cleanup deleting
   files older than 24 h and keeping newer ones.

### Slice 4 — Key bar, custom buttons, pointer extras
1. Esc, Tab, the arrows, ⏎, and ⌫ act on the Mac window.
2. ⌘ followed by typing "a" selects all. ⌘ ⇧ followed by "z" redoes. Modifiers disarm
   after use, and a long-press lock persists.
3. A custom button such as "⌘⇧4" or "Ctrl-C" can be created. It survives a page reload,
   works when tapped, and can be edited or deleted.
4. Long-press and release right-clicks, and a context menu appears. Long-press and drag
   selects text or moves a slider. Closing the socket during a drag leaves no stuck
   button.
5. *Unit:* the `KeyMap` table covers every name in §4.3, and the modifier event order is
   correct.

## 7. Testing approach
- **Swift unit tests** (`swift test`) cover the pure, bug-prone logic: coordinate
  mapping, framing, text chunking, key map, upload sniffing and cleanup, and the auth
  handshake with a test WebSocket client.
- Capture, CGEvent, and AX are verified by the manual device acceptance steps above,
  because mocks of those APIs would only mirror the implementation.
- No JavaScript test harness. The web client is small and is verified on a real device.

## 8. Human setup steps (documented in the README when implemented)
1. Install Tailscale on the Mac and the iPhone, signed in to the same tailnet. In the
   Tailscale admin console, enable **MagicDNS** and **HTTPS Certificates**.
2. Build and run the app (D17). Optionally set `CODESIGN_IDENTITY` so permissions survive
   rebuilds.
3. On the Mac, grant **Screen Recording** (then Relaunch) and **Accessibility** through
   the Setup window.
4. Run `tailscale serve --bg http://127.0.0.1:8765` once.
5. On an iPhone signed in to Tailscale with the **same account as the Mac** (§12 D32), open
   `https://<your-mac>.<tailnet>.ts.net/` in Safari. Optionally, use Share → **Add to
   Home Screen**. There is no pairing step.
6. Keep the Mac unlocked while using it remotely. Confirm macOS's periodic Screen
   Recording prompts when they appear.

## 9. Security summary
- The server is reachable only through loopback, so only `tailscale serve` (the tailnet)
  and local processes can reach it.
- All functionality requires the Mac owner's Tailscale identity (§12 D32), and there is
  one client at a time.
- *(§12 D32)* Access is limited to the Mac owner's Tailscale login, which `tailscale
  serve` asserts in `Tailscale-User-Login`. There is no secret to store or leak.
- Uploaded files go to the per-user temp directory with mode 0700 and are deleted after
  24 h.
- Anyone who can already run processes as the Mac user, or who controls a paired phone,
  can already control the Mac. Defending against that is out of scope.

## 10. Implementation notes (slice 1)
Facts found while implementing slice 1 that the sections above did not state. None of them
changes the UX, the protocol, or the permissions.

- **D7 content rect.** Apple documents `SCStreamFrameInfo.contentRect` as "points in
  surface", `scaleFactor` as the display's px per point, and `contentScale` as the
  original-to-surface scale. It does not document how they combine, and "`contentRect ×
  contentScale`" alone does not give image pixels on a Retina display. The server converts
  with `scaleFactor` and `contentScale`, and picks the reading that is closest to the full
  image. That is the steady state, because the output size follows the window size (D4).
  The result is clamped to the image. The chosen values are logged at debug level so the
  device check in slice 1 acceptance item 6 can confirm them.
- **D9 input source switch.** `TISSelectInputSource` does not take effect synchronously.
  The injector waits 60 ms after selecting the ASCII-capable source before it posts the
  text. It also waits 60 ms after posting, before it restores the saved source. It switches
  only when the current source is not already the ASCII-capable one. The TIS calls run on
  the main thread.
- **D6 Keychain access after a rebuild.** *(Obsolete: §12 D32 removed the Keychain.)*
  With the ad-hoc signature (D17), a rebuilt binary was a new code identity, and reading
  the Keychain item waited on a macOS "allow access" prompt.
- **D17 toolchain.** `scripts/build-app.sh` runs `xcrun swift`, so it uses the selected
  Xcode, or `DEVELOPER_DIR` when that is set, rather than whatever `swift` comes first in
  `PATH`. The current dependency graph (swift-crypto 5 through swift-nio-ssl) needs Swift
  6.3 or later to parse its manifest.
- **Slice 1 key names.** The phone sends only `Enter` and `Backspace` in slice 1, and the
  text chunker sends `Tab` for `\t`. `KeyMap` holds just those three. The server rejects
  other names and any non-empty `mods` with `bad_request`. The full §4.3 table arrives with
  the key bar in slice 4. *(§14 D34 adds the full §4.3 table and `mods`.)*
- **Slice 1 message size.** `/ws` accepts messages up to 1 MiB in slice 1. D12 raises the
  limit to 26 MiB when image upload arrives in slice 3. Binary client messages get
  `bad_request` until then.

## 11. Revision 2 — WebRTC transport and trackpad input (approved)

Why: on a real iPhone, slice 1 felt unusable. The cursor reacted late, one-finger drags
scrolled instead of moving the pointer, and the ack-gated JPEG stream updated slowly.
The user often connects from mobile networks through Tailscale, so the transport must
degrade gracefully under loss and variable bandwidth. The user approved these decisions:
trackpad-style relative input, three-finger pan, long-press drag lock, focus once per
target, and WebRTC from the start.

Scope: this revision replaces D3, D7, D8, and D14, and amends D4, D9, and D18. Pairing,
auth, the window list, text input (D10), permissions (D16), and later-slice features
(D11–D13) are unchanged, except that their messages travel over the data channel
(D22). Slices 2–4 keep their order after this revision ships.

### D20. WebRTC library for the Mac: `stasel/WebRTC` (SwiftPM binary xcframework)
- **Package:** `https://github.com/stasel/WebRTC.git`, pinned with `exact: "153.0.0"`
  (Chromium milestone M153). This is a binary target: a prebuilt, universal
  (arm64 + x86_64) `WebRTC.xcframework`, about 45 MB to download. It needs no Chromium
  build, depot_tools, or Xcode project. It has been maintained for years and its
  releases track Chromium milestones.
- **License:** the build scripts are BSD-3-Clause, and the binary is Google's WebRTC
  under its BSD-3-Clause license plus the WebRTC patent grant
  (`https://webrtc.org/support/license`). The xcframework ships its `LICENSE`; the app
  bundle copies it to `Contents/Resources/WebRTC-LICENSE`. H.264 encoding and decoding
  use Apple VideoToolbox, not a bundled codec, so no H.264 codec library is
  redistributed. The spike found no OpenH264 or FFmpeg symbols in the binary.
- **Spike on this Mac (2026-09, deleted afterwards),** built with Swift 6.3.1 through
  `xcrun swift build`:
  - The package resolves and links. Swift can import the `WebRTC` module, and the
    framework is embedded as `@rpath/WebRTC.framework`.
  - `RTCDefaultVideoEncoderFactory` offers H.264 (profiles `640c1f` and `42e01f`), VP8,
    VP9, and AV1.
  - An in-process sender and receiver negotiated with **no ICE servers**, reached ICE
    `connected` over host candidates, and moved a sendonly H.264 track and two data
    channels (one unordered with `maxRetransmits = 0`, one reliable). `outbound-rtp`
    reported `encoderImplementation = VideoToolbox`, and the receiver decoded every
    encoded frame.
  - Host candidate gathering with no STUN produced UDP and TCP candidates on every
    interface, **including the tailnet's CGNAT (100.64.0.0/10) address**.
  - **Found limitation (drives D21):** the stock H.264 encoder takes its VideoToolbox
    profile *and level* from the negotiated `profile-level-id`. With the offered levels
    (3.1), 1280×720 and 1024×768 encoded, but 1280×800, 1920×1080, and 2560×1600 failed
    with `kVTParameterErr` (-12902) and the encoder suspended. The same sizes encoded
    and decoded at level 5.2 (`640c34`). BGRA and NV12 input behaved the same.
- **App integration:**
  - `Package.swift` adds the product `WebRTC`. `scripts/build-app.sh` copies
    `WebRTC.framework` from the build products into `Contents/Frameworks/`, adds the
    `@executable_path/../Frameworks` rpath (a linker setting in `Package.swift`), and
    signs the framework before the app (`codesign --force --sign` for each, inner first).
  - `RTCInitializeSSL()` runs once at launch. One `RTCPeerConnectionFactory` lives for
    the app's lifetime.
- **Rejected alternatives:**
  - Building Chromium WebRTC from source: hours of build, a large toolchain, and no
    benefit for this app.
  - Pure-Swift or other WebRTC stacks: none on SwiftPM offer a mature SRTP, congestion
    control, and VideoToolbox H.264 path.
  - A Pion (Go) sidecar: a second process and language, which breaks D1.
  - LiveKit's `WebRTC-swift` binary: comparable, but it is tuned for the LiveKit SDK;
    stasel/WebRTC is the plain upstream build.

### D21. Video: ScreenCaptureKit → custom capturer → H.264 track
- **Capture** stays one `SCStream` with `SCContentFilter(desktopIndependentWindow:)`
  (D3/D4), with these changes:
  - `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12). VideoToolbox
    encodes it without a BGRA → YUV conversion.
  - `minimumFrameInterval = 1/30 s` (up from 1/15). WebRTC drops frames itself when
    bandwidth is short.
  - `showsCursor = false`. The phone draws its own cursor overlay (D24), which is never
    blurred by compression and never lags behind the video.
  - `queueDepth = 5`, `ignoreShadowsSingleWindow = true`, and skipping non-`.complete`
    frames stay. An idle window therefore produces no frames and no bandwidth.
  - **Output size:** window points × `pointPixelScale`, long edge capped at 2560 px
    (D4), then **rounded down to even width and height** (a 4:2:0 requirement).
- **Capturer:** a `WindowVideoCapturer: RTCVideoCapturer` wraps each complete sample's
  `CVPixelBuffer` in `RTCCVPixelBuffer` and calls
  `source.capturer(_:didCapture:)` with `RTCVideoFrame(rotation: ._0,
  timeStampNs: <sample PTS in ns>)`. The source is
  `factory.videoSource(forScreenCast: true)`, so WebRTC treats it as screen content
  (resolution is kept, and frame rate is reduced first under pressure).
- **Encoder factory:** `ScreenH264EncoderFactory: RTCVideoEncoderFactory`.
  - `supportedCodecs()` returns only H.264, with the usual profiles Constrained Baseline
    `42e01f` and High `640c1f`, `packetization-mode=1`, and `level-asymmetry-allowed=1`.
    These match what Safari offers, so negotiation succeeds. Offering only H.264 means
    negotiation cannot silently pick a software codec.
  - `createEncoder` passes the negotiated info to `RTCVideoEncoderH264` **with the level
    byte replaced by 5.2** (`42e034` or `640c34`, profile kept). Level 5.2 covers the
    2560×1600 cap at 30 fps. The spike showed that this encodes and decodes 1280×800,
    1728×1117, and 2560×1600, which fail at the negotiated level 3.1.
  - The stream can therefore exceed the level that the phone declared. Apple's hardware
    decoder handles level 5.2, so Safari is expected to play it; acceptance 1 checks this
    on the device (see the risks at the end of this section).
- **Track:** one video track (`trackId = "window"`) on the offer's transceiver, set to
  `sendonly` (D22), with `setCodecPreferences` to the H.264 entries of
  `rtpSenderCapabilities`.
  - Sender parameters: `degradationPreference = maintainResolution` (text stays sharp;
    the frame rate drops instead), `maxBitrateBps = 8_000_000`,
    `maxFramerate = 30`.
  - Bitrate and frame rate then follow WebRTC's congestion control (transport-wide
    congestion control, NACK retransmission, and PLI/FIR keyframe requests). The app
    adds no bitrate logic of its own.
- **Resize:** when the 500 ms bounds poll (D4) sees a size change, the server calls
  `stream.updateConfiguration` with the new even-rounded size. The capturer then emits
  frames of the new size, and the encoder reconfigures and sends a keyframe by itself.
  The `<video>` element on the phone follows the intrinsic size change.
- **Window change:** `view.start` for another window stops the old `SCStream` and starts
  a new one feeding **the same capturer and track**. No renegotiation is needed.
- **Idle:** when nothing is viewed, the transceiver stays; the capturer simply delivers
  no frames.

### D22. Signaling and data channels
- **Signaling** runs over the existing authenticated `/ws` WebSocket (D2, D6), so it
  inherits pairing, auth, and the single-client rule. The **phone is the offerer**; the
  Mac answers. Each peer connection has a `pc` sequence number chosen by the client, and
  the server ignores messages whose `pc` is not the current one.
- **Order of events:**
  1. After `hello`, the client creates an `RTCPeerConnection` with
     `{iceServers: [], bundlePolicy: "max-bundle"}` and a `recvonly` video transceiver.
  2. It creates the two data channels (below), creates an offer, applies it locally,
     and sends `rtc.offer`.
  3. The server creates its peer connection and applies the offer. It then takes the
     offer's video transceiver, sets its direction to `sendonly`, attaches the track
     (D21) with `sender.track`, applies the H.264 codec preferences, answers, and sends
     `rtc.answer`.
  4. Both sides trickle ICE candidates with `rtc.ice` as they are gathered. An end of
     candidates is sent as `rtc.ice` with `candidate: null`.
  5. When the client's `connectionState` becomes `connected`, the client sends
     `windows.list` and continues as in slice 1.
- **Data channels,** created by the client before the offer, so both are in the SDP:
  | Label | Options | Carries |
  |---|---|---|
  | `motion` | `ordered: false`, `maxRetransmits: 0` | `move`, `scroll` |
  | `control` | reliable, ordered (defaults) | every other input message, and all server results for input |
  - Each data channel message is one UTF-8 JSON object with a `t` field (§4.2 style).
  - Losing a `motion` message is harmless, because each `move` carries its own delta and
    the next one continues; a lost delta only makes that one step shorter.
- **What stays on the WebSocket:** `auth`, `hello`, `windows.list`/`windows`,
  `view.start`/`view.stop`/`view.state`, `ping`, the `rtc.*` signaling messages, and
  `error` for those. Input and input results move to the data channels. Upload and
  clipboard messages (slices 2–3) use `control`; images larger than one data channel
  message are split as described when slice 3 is implemented.
- **Single client:** replacing a session (4002, D6) also closes its peer connection.

### D23. Trackpad gestures (replaces D14)
The viewer uses `touch-action: none`, so every gesture is custom. The recognizer is a
pure state machine in `web/gestures.js` that consumes touch points and time and emits
intents; `viewer.js` wires DOM events to it. Thresholds are constants at the top of the
file.

| Gesture | Effect |
|---|---|
| 1 finger move | Relative cursor move (D24). Never warps to the touch point. |
| 1 finger tap | Left click at the current cursor. While a drag lock is active, the tap releases it instead (mouse up). |
| 1 finger long-press | Starts a drag lock: left button down at the current cursor. Later 1-finger moves send drags. A **"Dragging — tap to release"** badge stays visible. |
| 2 finger tap | Right click at the current cursor. |
| 2 finger move | Scroll, both axes (natural direction: content follows the fingers). |
| 3 finger move | Pan the zoomed view on the phone only. |
| Pinch (2 fingers, distance changes) | Zoom the view on the phone only, 1× (fit) to 8×. The Fit button resets zoom and pan. |

- **Thresholds:**
  - `TAP_SLOP = 8` CSS px: a touch that moves less than this is still a tap or long-press
    candidate. Movement is the max distance of any finger from its start.
  - `TAP_MAX_MS = 250`: a tap lifts within this time.
  - `LONG_PRESS_MS = 450`: a single finger held still this long starts the drag lock,
    confirmed with a short vibration where `navigator.vibrate` exists (it does not on
    iOS; the badge is the confirmation).
  - `PINCH_START = 12` CSS px change in finger distance decides pinch over 2-finger
    scroll. Once a 2-finger gesture is classified, it stays that kind until all fingers
    lift.
- **States:** `idle → one(pending) → one(moving) | tap | longPress`,
  `idle → two(pending) → two(scroll) | two(pinch) | twoTap`, and
  `three(pan)`. Adding a finger upgrades the gesture (1→2→3) and cancels a pending tap;
  removing fingers ends it when the count reaches zero. A gesture never downgrades, so a
  lifted second finger does not turn a scroll into a cursor move.
- **Tap timing:** taps are sent on lift. There is no double-tap recognition, so a single
  tap is never delayed. A double-click is two quick taps; the Mac turns them into a
  double-click by itself when they are close in time and place (D26).
- **Drag lock:** only a long-press starts it; only a tap (or disconnect) ends it. Two-
  and three-finger gestures during a drag lock work normally and keep the button held.

### D24. Relative cursor and the cursor overlay
- **Source of truth:** the Mac owns the cursor position for the viewed window, stored
  as window-normalized coordinates `(cu, cv)` in [0, 1] × [0, 1] on the input actor.
  It starts at the window's center when viewing starts.
- **Client delta → server:** a 1-finger move sends `{t:"move", dx, dy}` in
  **window-normalized units**, computed from finger CSS px as
  `dx = fingerDx × SENSITIVITY / (videoCssWidth × zoom)` (and likewise for `dy`), where
  `videoCssWidth` is the width of the video at fit. So one finger-width of travel moves
  the cursor the same distance on the visible video at any zoom, and `SENSITIVITY = 1.5`
  makes a thumb-sized swipe cover a useful distance.
  - Moves are coalesced in the client: at most one `move` per animation frame, carrying
    the sum of deltas since the last send.
- **Server:** it adds the delta to `(cu, cv)`, **clamps to [0, 1]**, maps to global
  points with the window's current bounds (`bounds.origin + (cu × w, cv × h)`, queried
  now), and posts `mouseMoved`, or `leftMouseDragged` while the drag lock is held.
  - The cursor therefore never leaves the target window, and a window moved on the Mac
    keeps the cursor at the same place inside it.
- **Overlay:** the phone draws a cursor arrow over the `<video>` at `(cu, cv)`.
  - The client predicts locally: it applies each sent delta immediately, with the same
    clamp, so the arrow moves with the finger at display rate.
  - The server confirms: on `control` it sends `{t:"cursor", u, v, seq}` after each
    applied move batch, at most 30 times per second, where `seq` echoes the highest
    `move.seq` it applied. The client re-bases its prediction on it and re-applies only
    the deltas sent after `seq`. The overlay is thus correct even when `motion`
    messages are lost.
  - The overlay is drawn in video coordinates, so zoom and pan move it with the image.
  - When the view is zoomed and the cursor leaves the visible area, the view does not
    follow; the user pans with three fingers (approved behavior).
- **Clicks, scrolls, and drags** act at `(cu, cv)` as confirmed by the server, never at
  a touch point.
- `stale_coordinates` is no longer produced: the clamp makes every cursor position valid.

### D25. Focus policy (replaces the per-input wait in D8)
- The input actor keeps `focusedWindowId`. Before an input that needs the window in
  front (click, drag start, scroll, text, key), it checks whether the target is the
  frontmost layer-0 window (D8 step 1, a cheap `CGWindowList` call).
  - If it is frontmost, nothing else happens.
  - If not, it runs D8 steps 2–3 (activate, AX raise) **once** and records the target
    as focused. It does **not** poll or wait.
- Focus is requested when viewing starts, when the viewed window changes, and when an
  input finds the target not frontmost. It is never requested for a plain cursor
  `move`: moving the pointer over a background window does not need focus.
- **The first click after a focus change** is posted 80 ms after the raise, which gives
  the window server time to put the window in front. This is the only delay, and it
  applies only when a raise happened for that input.
- **Coalescing:** the input actor keeps one pending `move` accumulator and one pending
  `scroll` accumulator. Arriving moves and scrolls add to them; the actor drains them
  before each discrete input and after each event loop turn. Discrete inputs (clicks,
  drag state, keys, text) are ordered and never dropped. So cursor movement never
  queues behind a slow input.

### D26. Input injection changes (amends D9)
- `move`: `mouseMoved` (or `leftMouseDragged` during a drag lock) at the new cursor
  point. The event source is still `.hidSystemState`, posted to `.cghidEventTap`.
- `click`: `leftMouseDown`/`leftMouseUp` at the cursor. The server tracks the last click
  time and position; a second click within `NSEvent.doubleClickInterval` and 4 pt of
  the first gets `mouseEventClickState = 2` (then 3), so double- and triple-clicks work
  from quick taps.
- `rightClick`: `rightMouseDown`/`rightMouseUp` at the cursor.
- `drag`: `{state:"start"}` posts `leftMouseDown` at the cursor; `{state:"end"}` posts
  `leftMouseUp` at the cursor. A disconnect, a peer connection failure, a window change,
  or `view.stop` during a drag posts `leftMouseUp`, so a button is never left stuck.
- `scroll`: `CGEvent(scrollWheelEvent2Source:units:.pixel, wheelCount:2, …)` at the
  cursor, with deltas in points: `du × window.w` and `dv × window.h`, where the client
  computes `du`/`dv` from finger movement divided by the fit-size video dimensions and
  zoom, like `move` but without the sensitivity factor.
- `text` and `key`: unchanged (D9, D10).

### D27. ICE configuration and media failure
- **ICE config:** `iceServers: []` on both sides. No STUN or TURN server is configured
  or contacted, so no third party sees the connection.
  - Candidates are host candidates only. The phone and the Mac both have a tailnet
    address, so a host candidate pair over the tailnet interface connects directly
    (or through Tailscale's own DERP relay when a direct path is impossible). The spike
    confirmed that the Mac gathers its tailnet host candidate.
  - Candidates from other interfaces (LAN, IPv6) are also offered. When the phone is on
    the same LAN, ICE may pick a faster LAN pair; that is fine, because it is still
    DTLS-SRTP between the paired devices.
  - The Mac keeps `continualGatheringPolicy = gatherContinually`, so a new interface
    (for example, the phone switching from Wi-Fi to cellular) is handled by ICE restart
    from the client (below).
  - Candidate addresses are never logged, only their type and protocol.
- **Client state handling** (`RTCPeerConnection.connectionState`):
  | State | Client behavior | User sees |
  |---|---|---|
  | `connecting` (up to 10 s) | wait | "Connecting video…" over the last image |
  | `connected` | clear overlays | video |
  | `disconnected` | wait 3 s for recovery, then send an ICE restart offer (`iceRestart: true`) | "Reconnecting…" |
  | `failed`, or `connecting` longer than 10 s | close the peer connection and start a fresh one once; if that also fails, stop and show the error | "Could not connect video over the tailnet. Check that Tailscale is on for both devices." with a **Retry** button |
  - If the WebSocket itself drops, the peer connection is closed and D18's reconnect
    runs; after `hello`, a fresh peer connection is negotiated and the last window is
    resumed.
  - **There is no fallback to JPEG.** The old pipeline is deleted (D3).
- **Server:** a peer connection that is `failed` or `closed` stops capture, releases a
  held button (D26), and releases the display assertion (D15). Only one peer connection
  exists; a new `rtc.offer` replaces the old one.

### D28. Protocol changes (amends §4)
WebSocket, client → server (new):
```jsonc
{"t":"rtc.offer","pc":1,"sdp":"v=0…"}
{"t":"rtc.ice","pc":1,"candidate":"candidate:… typ host …","sdpMid":"0","sdpMLineIndex":0}
{"t":"rtc.ice","pc":1,"candidate":null}
```
WebSocket, server → client (new):
```jsonc
{"t":"rtc.answer","pc":1,"sdp":"v=0…"}
{"t":"rtc.ice","pc":1,"candidate":"…","sdpMid":"0","sdpMLineIndex":0}
```
Removed from the WebSocket: `frame.ack`, the binary `frame` message, `pointer`,
`scroll`, `text`, and `key` (they move to the data channels).

Data channel `motion`, client → server:
```jsonc
{"t":"move","seq":812,"dx":0.0123,"dy":-0.004}
{"t":"scroll","du":0.0,"dv":-0.03}
```
Data channel `control`, client → server:
```jsonc
{"t":"click"}                       // left click at cursor; while a drag lock is held the client sends drag end instead
{"t":"rightClick"}
{"t":"drag","state":"start|end"}
{"t":"text","text":"こんにちは"}
{"t":"key","key":"Enter","mods":[]}
```
Data channel `control`, server → client:
```jsonc
{"t":"cursor","u":0.431,"v":0.227,"seq":812}
{"t":"error","code":"permission_accessibility","message":"…"}
```
- `view.state` gains nothing; the client learns the window size from the `<video>`
  element's intrinsic size, and the overlay uses normalized coordinates, so no frame
  header is needed.
- Validation: `dx`, `dy`, `du`, `dv` must be finite and within [-1, 1]; `seq` is a
  non-negative integer; `state` is one of the two values. Anything else is
  `bad_request` on `control` and silently dropped on `motion`.
- Error codes: `stale_coordinates` is removed. `rtc_failed` is added for a server-side
  failure to create an answer (sent on the WebSocket, with the client showing the D27
  error).

### D29. Source changes
| File | Change |
|---|---|
| `mac/Package.swift` | add `stasel/WebRTC` `exact: "153.0.0"`; rpath linker setting |
| `scripts/build-app.sh` | embed and sign `WebRTC.framework`; copy its LICENSE |
| `RTCHost.swift` (new) | factory, encoder factory (D21), peer connection lifecycle, signaling, data channel routing |
| `WindowVideoCapturer.swift` (new) | `RTCVideoCapturer` subclass fed from `SCStream` samples |
| `CaptureSession.swift` | NV12, even sizes, 30 fps, no cursor; deliver buffers to the capturer; remove JPEG encode, ack flow control, and the frame header ring |
| `CursorState.swift` (new, replaces `CoordinateMapper.swift`) | pure: apply delta + clamp, map to global point with current bounds, click-count tracking |
| `WindowFocuser.swift` | focus-once policy (D25), no polling wait |
| `InputInjector.swift` / `MacBackend.swift` | coalesced move/scroll, drag lock, release on teardown |
| `Protocol.swift` / `Session.swift` | `rtc.*` messages; data channel message decode; remove frame messages |
| `web/rtc.js` (new) | peer connection, signaling, data channels, D27 state handling |
| `web/gestures.js` (new) | pure gesture state machine (D23) |
| `web/viewer.js` | `<video>` instead of canvas, zoom/pan transform, cursor overlay, drag badge |
| `web/app.js` | wire rtc and viewer; remove binary frame handling |

### D30. Revision 2 acceptance criteria
All device checks run on a real iPhone (Safari) against the real Mac through
`tailscale serve`, first on the same Wi-Fi and then with the phone **on cellular with
Wi-Fi off**.
1. After pairing and picking a window, video appears within 3 s on Wi-Fi and within 5 s
   on cellular. The Mac log shows the negotiated codec H.264 and encoder VideoToolbox.
2. Typing in a Mac window shows the change on the phone within about 200 ms on Wi-Fi
   (judged by eye against the Mac screen). Scrolling a long page stays fluid rather than
   stepping frame by frame.
3. An idle window sends almost nothing: the WebRTC stats on the Mac show the outbound
   bitrate falling to near zero within 5 s of the window becoming static.
4. One-finger movement moves the Mac pointer relatively, in the finger's direction, with
   no jump to the touch point. The overlay arrow on the phone and the real Mac pointer
   end at the same place. The pointer never leaves the window.
5. A tap clicks at the overlay arrow. Two quick taps on a word select it. A two-finger
   tap opens a context menu. A two-finger move scrolls a page vertically and
   horizontally; a one-finger move never scrolls. A three-finger move pans the zoomed
   view; pinch zooms to 8× and Fit resets.
6. A long-press shows "Dragging — tap to release"; moving then drags (for example, selects
   text or moves a window's slider); a tap releases. Disconnecting Wi-Fi during a drag
   leaves no stuck button on the Mac.
7. Operating a window that is behind another brings it to the front once; later inputs
   to it have no added delay. Plain cursor movement does not bring it to the front.
8. Switching the phone from Wi-Fi to cellular while viewing recovers within 10 s with
   "Reconnecting…" shown in between. Turning Tailscale off on the phone shows the D27
   error with Retry; turning it on and tapping Retry recovers.
9. Text input (D10) still works, including Japanese IME and dictation.
10. *Unit:*
    - Gesture state machine: tap, long-press, move, drag lock and release, two-finger
      tap, scroll versus pinch classification, three-finger pan, and the finger-count
      upgrade and no-downgrade rules.
    - `CursorState`: delta application, clamping at all edges, mapping to a moved
      window, and click-count timing and distance.
    - Data channel and signaling message decoding, including rejecting non-finite or
      out-of-range deltas.

### D31. Human setup changes
- A rebuilt ad-hoc-signed app needs Screen Recording and Accessibility granted again
  (D17). The practical fix is switching the existing entry off and on in System
  Settings, which a person must do.
- No new permission is needed. WebRTC uses outgoing and incoming UDP on the tailnet
  interface; with the macOS application firewall on, macOS may ask once whether
  `MacWindowRemote` may accept incoming connections, and a person must allow it.
- `tailscale serve` is unchanged: it still carries only the page and the signaling
  WebSocket. Media does not go through it.
- The README gains a "Using it on cellular" note: Tailscale must be on for both
  devices, and no port forwarding is needed.

### Revision 2 risks (to be checked on the device)
- **H.264 level above the declared one (D21):** the encoder sends level 5.2 while
  Safari declares 3.1. If Safari refuses to decode it, the fallback in design is to cap
  the output at the largest size that level 4.2 allows in the SDP and negotiate that
  instead; this needs a design update, not a silent change.
- **Tailnet UDP path:** when Tailscale cannot make a direct path, traffic goes through
  DERP relays, which carry UDP-in-TCP and add latency. That is Tailscale's behavior, not
  something the app controls; the acceptance run on cellular shows the real result.
- **iOS Safari background:** Safari suspends the peer connection when the page is hidden;
  D15/D18 already close and rebuild the session on `visibilitychange`.
- **ICE on iOS without STUN:** Safari hides local addresses behind mDNS names for pages
  without camera permission. The Mac library resolves `.local` mDNS candidates only on
  the same LAN, so on cellular the phone's tailnet candidate must be offered as a raw
  address or the connection must be completed by the Mac's candidates (the phone then
  learns a peer-reflexive candidate). The spike did not cover a phone; acceptance 1 on
  cellular is the check. If it fails, the fix to design is a Mac-side note in D27, not a
  public STUN server.

### Revision 2 implementation notes (step 1: trackpad input on the slice 1 transport)
Step 1 ships D23–D26 and the D28 input messages before the WebRTC transport (D20–D22,
D27), so the trackpad model can be used now. None of these notes changes the UX that
§11 describes; step 2 removes the interim parts.

- **Interim transport.** Until the data channels exist, the D28 `motion` and `control`
  messages (`move`, `scroll`, `click`, `rightClick`, `drag`, `text`, `key`) and the
  server's `cursor` message travel on the authenticated WebSocket. Invalid `move` or
  `scroll` messages are dropped silently, as they will be on `motion`; the others get
  `bad_request`. The JPEG frames, `frame.ack`, and the frame header stay until D21.
- **Overlay placement.** The overlay and the D24 delta scale use the frame header's
  content rect in place of the `<video>` intrinsic size, which does not exist yet. The
  scale is the same quantity: the content's width and height in CSS px at the current
  zoom.
- **Cursor edges.** `(cu, cv) = (1, 1)` maps to 1 pt inside the right and bottom edges,
  because the point at `maxX`/`maxY` belongs to whatever is next to the window. The
  clamp itself stays [0, 1].
- **Click count distance.** "Within 4 pt" (D26) is the Euclidean distance. A right-click
  or drag start resets the count.
- **Gesture timing gaps.** A still single touch that lifts after `TAP_MAX_MS` but before
  `LONG_PRESS_MS` does nothing. If the long-press timer has not fired when a still touch
  lifts after `LONG_PRESS_MS`, the lift starts the drag lock. After a gesture upgrades
  (1→2→3 fingers), tap slop is measured from where the fingers were at the upgrade.
- **Motion ordering.** Discrete inputs post the move and scroll that arrived before them
  first; motion posts never overlap. A click is posted at the cursor as it was when the
  click arrived. If later moves were already posted, the pointer is moved back to the
  current cursor afterwards.
- **Focus.** D25's focus request "when viewing starts" happens after the capture starts.
  `drag end` does not request focus, because the button is released where the drag is.
- **JavaScript unit tests.** §7 says there is no JavaScript test harness, but D30 item 10
  requires unit tests for the gesture state machine, which is JavaScript. They use
  Node's built-in `node:test` with no dependencies and no build step
  (`node --test tests/web/*.test.mjs`). Nothing is added to the web client.

### Revision 2 implementation notes (step 2: WebRTC transport)
Step 2 replaces the JPEG stream with D20–D22 and D27 and moves input to the D28 data
channels. The interim WebSocket input and the JPEG frames of step 1 are gone.

- **Codec preferences overload.** The Objective-C `setCodecPreferences:error:` and the
  deprecated non-throwing `setCodecPreferences:` import into Swift under the same name,
  and Swift picks the deprecated one. It is used as is (it logs and ignores an error),
  so the build shows one deprecation warning. The answer's H.264-only codec list is the
  check that it took effect.
- **Even sizes.** The capture output size is rounded down to even width and height,
  because 4:2:0 NV12 and the H.264 encoder need them. The long-edge cap of 2560 px (D4)
  is applied first.
- **Motion post waiting.** A discrete input waits until no move or scroll post is in
  progress (step-1 note "Motion ordering"). A finished post is now cleared by whichever
  waiter sees it first. Before, a waiter awaited the finished post again; that returns at
  once, so it spun on the actor and every later input stopped (seen as 100 % CPU in the
  step-2 harness). `InputPipelineTests` guards it.
- **Verification without the app.** A test-only harness (not committed) ran the real
  `Server`, `SessionHub`, `RTCHost`, and data channels against headless Chrome, with
  synthetic NV12 frames in place of ScreenCaptureKit and a proxy adding
  `Tailscale-User-Login`. H.264 video decoded at 2560×1600; all input kinds reached the
  backend in order; wrong-channel and invalid messages got `bad_request` on `control`.
  Real window capture, iOS Safari, and cellular are covered only by §11's acceptance on
  the device.

## 12. Access by Tailscale identity (approved by the user; supersedes D6)

### D32. Authentication: the Mac owner's Tailscale login
- **Why (user decision):** pairing does not work for the user's real use. The pairing
  code has to be carried to the phone, and when the user connects remotely there is no
  Mac screen at hand to scan a QR code or copy a code from. Storing the secret also caused
  macOS Keychain password dialogs on every ad-hoc rebuild. `tailscale serve` already knows
  who is connecting, so the Mac uses that identity instead.
- **Rule:** the server stays bound to `127.0.0.1` (D2). For every HTTP request and the
  `/ws` upgrade, the `Tailscale-User-Login` header, which `tailscale serve` adds for a
  signed-in tailnet user, must equal the **allowed login** (compared ignoring case and
  surrounding spaces).
  - Allowed login = Settings override if set, else the owner of this Mac's Tailscale
    node: `tailscale status --json` → `Self.UserID` → `User[<id>].LoginName`.
  - The CLI is found at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, then
    `/opt/homebrew/bin/tailscale`, `/usr/local/bin/tailscale`, then `PATH`. The answer is
    cached for the process lifetime. While it is unknown (Tailscale not installed, not
    running, or logged out) the CLI is asked again at most every 30 s, and **every request
    is rejected**.
  - No header (direct local access, or a tagged device, which has no user login) or
    another login is rejected: HTTP **403** with the text "Not allowed: sign in to
    Tailscale as the Mac owner"; `/ws` is upgraded and then closed with **4001**
    (`not_allowed`), because a refused upgrade reaches the page only as an unexplained
    error. The phone shows a **Not allowed** screen with that sentence, a note that the
    allowed account is shown in the Mac menu, and **Try again**.
  - The header value is never logged; logs record only the reason (`missingHeader`,
    `otherUser`, `ownerUnknown`).
- **Removed:** the pairing secret and its storage (Keychain or file), `auth` message and
  `4003`, Pair iPhone… (QR and code), Reset pairing…, the iPhone URL setting, and the
  phone's Pair screen. The phone deletes a leftover `mwr.secret` from `localStorage`.
- **Kept:** single client (a new session replaces the old one with 4002), `hello` as
  the first server message, everything after it.
- **Mac UI:** the menu shows "Allowed: <login>" (or "Allowed: unknown (sign in to
  Tailscale)"). Setup and Settings show the allowed login field (empty = this Mac's
  login).
- **Threat note (user decision):** a malicious local process on the Mac can connect to
  `127.0.0.1` and send a forged `Tailscale-User-Login` header. This is out of scope: a
  malicious process running as the user is already a more serious compromise than this
  app, and it can post input events itself. Remote tailnet devices cannot forge the
  header, because `tailscale serve` sets it from the WireGuard peer identity and drops a
  client-supplied value.
- **Human setup:** no pairing step. Sign in to Tailscale on the iPhone with the same
  account as the Mac, run the `tailscale serve` command once, and open the https URL it
  prints in Safari (optionally Share → Add to Home Screen).


## 13. Viewer bottom bar and quick-switch slots (user decision)

### D33. No top bar; back, Fit, and three quick-switch slots in the bottom bar
- **Why (user decision, after using revision 2 on the iPhone):** the auto-hiding top bar
  (§3) was undiscoverable: nothing showed that tapping the top edge brings it back, so
  the way back to the window list and Fit were effectively hidden. Switching between a
  few windows also took a trip through the list every time.
- **Layout.** The viewer has no top bar and no top-edge tap. The bottom bar is always
  visible and, left to right, holds **‹** (back to the window list, with the small
  connection dot on its corner), **slot 1–3**, **Fit**, and **⌨︎**. While typing (D10)
  the slots and Fit are hidden so the text field has room; ‹ and ⌨︎ stay. The video stage
  fills the screen above the bottom bar, inside the safe-area insets (top, left, right;
  the bar's own padding covers the bottom inset). The bar still moves above the
  keyboard. The window title is no longer shown in the viewer.
- **Slots.** Up to three, stored on the phone in `localStorage` (`mwr.slots`) as
  `{windowId, app, title}` or empty. Window ids change when an app restarts, so a slot
  is resolved against the latest window list (`windows`):
  1. a window with the same `windowId`;
  2. else a window with the same app and title (the first in list order);
  3. else the only window of the same app;
  4. else the slot is **unavailable** (greyed).
  A slot resolved to a window stores that window's current id and title, so the next
  resolution matches by id. Before the first list arrives, a slot is used as stored.
- **Slot actions.**
  - Tap an empty slot ("+"): assign the currently viewed window to it.
  - Tap an assigned slot: switch the viewer to that window at once with `view.start`
    (the same path as picking from the list). Tapping the slot of the current window
    does nothing.
  - Tap an unavailable slot, or long-press (500 ms) any slot: a small menu with
    **Assign current window** and **Clear**; tapping outside closes it.
  - The slot of the window being viewed is highlighted.
- **Switching keeps the peer connection.** The capture track is fed by one custom
  capturer (D21) and `view.start` while viewing already stops the old capture and starts
  the new one (D18), so the video track, the data channels, and the ICE path stay; there
  is no renegotiation. The phone shows the new window's first frame as in D21
  (`awaitFirstFrame`).
- **Thumbnails.** Each assigned, resolved slot shows a small image of its window. Without
  one it shows the app name.
  - Phone → Mac on the WebSocket: `{"t":"thumbs.request","windowIds":[1234,5678]}`, at
    most 3 ids (more, or a missing array, is `bad_request`).
  - Mac → phone, one message per requested id:
    `{"t":"thumb","windowId":1234,"jpeg":"<base64>"}`, or
    `{"t":"thumb","windowId":1234,"missing":true}` when the window is not on screen
    (closed, minimized, another Space), capture fails, or Screen Recording is missing.
  - The Mac takes one `SCShareableContent` snapshot per request and uses
    `SCScreenshotManager` for each id: long edge at most 160 px, no cursor, no shadow,
    JPEG quality 0.6. A newer request cancels the replies of an older one still in
    progress. Thumbnails are only for the requested slot windows, never the whole list.
  - When the phone requests: when the viewer opens, after a reconnect, every 10 s while
    the viewer is visible, and at once when a slot changes. On open, reconnect, and the
    10 s tick the phone first sends `windows.list`, resolves the slots against the reply,
    then requests thumbnails for the resolved ones, so a restarted app is re-resolved
    within 10 s. Thumbnails are kept in memory only.
- **Source changes:** `web/index.html`, `web/style.css`, `web/viewer.js` (top bar and
  top-edge tap removed), `web/app.js` (slots wiring, `thumb` handling, 10 s tick),
  `web/slots.js` (new: pure slot resolution and `thumb` decode), `web/slotbar.js` (new:
  slot buttons and menu); `Protocol.swift` (`thumbs.request`, `thumb`), `Session.swift`,
  `MacBackend.swift`, `WindowThumbnail.swift` (new: screenshot and JPEG encode).

### D33 acceptance criteria
On a real iPhone against the real Mac:
1. The viewer shows no top bar; the bottom bar shows ‹ (with the connection dot), three
   slots, Fit, and ⌨︎ in that order, with nothing under the notch or home indicator in
   portrait and landscape. The video uses the full height above the bar.
2. ‹ returns to the window list; Fit resets zoom and pan; tapping near the top of the
   video is an ordinary click.
3. Tapping an empty slot assigns the current window; its thumbnail appears within about
   a second and it is highlighted. Tapping another assigned slot switches to that window
   within about a second without "Connecting video…", and the highlight moves.
4. Long-press on a slot shows Assign current window / Clear; both work.
5. Slots survive closing and reopening Safari. After quitting and relaunching an app
   whose window is in a slot, the slot finds the new window (same title, or the app's
   only window) within 10 s; if the window is gone the slot is greyed and tapping it
   offers Clear.
6. Thumbnails refresh about every 10 s while the viewer is open, and no `thumbs.request`
   is sent while the list is shown or Safari is in the background.
7. *Unit:* slot resolution rules 1–4; `thumbs.request` decoding (including more than 3
   ids and a missing array); `thumb` encoding and the phone's `thumb` decoding.

## 14. Key panel (user decision; supersedes the D13 key bar layout)

### D34. A 2×6 key panel toggled by ⌨︎
- **Why (user request, with a reference image):** the iOS keyboard cannot type Esc, Tab,
  arrows, F-keys, or ⌘/⌃/⌥ shortcuts such as ⌘C, ⌘V, and ⌃C. The panel gives those keys
  large targets. Custom buttons (D13) are not part of this step.
- **Entry.** ⌨︎ in the bottom bar (D33) toggles the key panel; ⌨︎ is highlighted while
  the panel is open. It no longer opens the iOS keyboard directly; the panel's **text**
  key does. Closing the panel also hides the iOS keyboard, and leaving the viewer closes
  the panel.
- **Layout.** The panel sits directly above the bottom bar and moves with it above the
  iOS keyboard. Keys are large dark rounded buttons in a grid of six equal columns that
  spans the safe-area width (at most 640 px wide, centered, in landscape). While the
  panel is open the video stage ends at the panel's top edge (the stage shrinks and the
  video re-fits), so the panel never hides part of the window. With the iOS keyboard up,
  the keyboard and panel cover the lower part of the stage, as the bar already does (D33).
  - Normal layer:
    | esc | ⇧ | tab | fn | ↑ | text |
    |---|---|---|---|---|---|
    | ⌃ | ⌘ | ⌥ | ← | ↓ | → |
  - **fn layer** (fn is highlighted; tap fn again to return). Twelve F-keys and fn do not
    fit 12 slots, so this layer has a third row; the panel grows by one row while it is
    shown:
    | F1 | F2 | F3 | F4 | F5 | F6 |
    |---|---|---|---|---|---|
    | F7 | F8 | F9 | F10 | F11 | F12 |
    | fn | Home | End | PgUp | PgDn | ⌦ |
  - Modifiers are armed in the normal layer and stay armed across the switch, so ⌘ then
    fn then F5 sends ⌘F5. The layer stays until fn is tapped again.
- **Key names sent** (§4.3): esc `Escape`, tab `Tab`, arrows `ArrowUp/Down/Left/Right`,
  `F1`–`F12`, `Home`, `End`, `PageUp`, `PageDown`, ⌦ `Delete` (forward delete).
- **Modifiers ⇧ ⌃ ⌘ ⌥ (one-shot, from D13).**
  - Tap: off → armed (highlighted) → tap again → off. A long press (500 ms) locks it
    (a stronger highlight) until it is tapped again.
  - The next key — a panel key, or Return/Backspace from the text field (D10) — is sent
    as `key` with the active modifiers, in the order cmd, ctrl, opt, shift. Armed
    modifiers then disarm; locked ones stay.
  - While any modifier is active, a single committed character typed on the iOS keyboard
    that is `[a-z0-9]` or ANSI punctuation (§4.3) is not inserted into the field; it is
    sent at once as `key` with the modifiers (⌘ then "c" is ⌘C). A space is sent as
    `Space`. Anything else (an uppercase letter, IME composition, pasted or longer text)
    goes into the field as usual and is sent as plain `text` on Return; sending text
    disarms armed modifiers.
- **text key.** Focuses the existing text field so the iOS keyboard appears (IME and
  Japanese input work as in D10); tapping it again while the keyboard is up hides it.
  Panel keys do not take focus, so tapping them keeps the iOS keyboard open.
- **Auto-repeat.** ←↑↓→, ⌦, PgUp, and PgDn repeat while held: the first `key` on press,
  then after 400 ms about 15 per second (every 66 ms) until the finger lifts or leaves
  the key. The modifiers active at the press apply to every repeat. Other keys send once
  on press.
- **Feedback.** A pressed key shows a brief highlight (iOS Safari has no vibration API).
- **Protocol.** `key` on the `control` data channel (D28) with optional
  `mods` (default `[]`): `{"t":"key","key":"c","mods":["cmd"]}`. The Mac accepts the key
  names in §4.3 and the mods `cmd`, `ctrl`, `opt`, `shift`, each at most once; an unknown
  key or mod, or a repeated mod, is `bad_request`. Unchanged on the WebSocket.
- **Mac injection** (D9, through the D25 focus pipeline): modifier key-downs with
  cumulative flags, the key down/up with all flags, then modifier key-ups in reverse.
- **Source changes:** `KeyMap.swift` (full §4.3 table, `KeyModifier`, combo event order),
  `Protocol.swift` (`key` mods), `InputPipeline.swift`, `Session.swift`,
  `MacBackend.swift`, `InputInjector.swift`; `web/modifiers.js` (new: modifier state and
  character → key name), `web/keypanel.js` (new: the panel), `web/input.js` (modifiers
  on keys and single characters), `web/app.js`, `web/index.html`, `web/style.css`.

### D34 acceptance criteria
On a real iPhone against the real Mac:
1. ⌨︎ shows and hides the 2×6 panel above the bottom bar in portrait and landscape,
   nothing under the notch or home indicator; the video re-fits above the panel.
2. esc, tab, and the arrows act on the Mac window; holding an arrow repeats after about
   0.4 s.
3. ⌘ then typing "c" on the iOS keyboard copies; ⌘ then "v" pastes; ⌃ then "c" in
   Terminal interrupts. ⌘ disarms after use; a long-pressed ⌘ stays until tapped.
4. text opens the iOS keyboard with the panel above it; Japanese input still sends on
   Return; tapping panel keys does not close the keyboard; text again hides it.
5. fn shows F1–F12 plus Home/End/PgUp/PgDn/⌦; F-keys work; fn returns to the normal layer.
6. *Unit:* Mac `key` decoding with `mods` (valid, unknown, repeated), the `KeyMap` table
   and combo event order; the web modifier state machine (arm, one-shot, lock, disarm on
   text) and character → key mapping.
