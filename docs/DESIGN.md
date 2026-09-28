# mac-window-remote — Design (v0.2)

Status: **slice 1 implemented (JPEG over WebSocket, absolute taps). Revision 2 (§11)
replaces the transport with WebRTC and the pointer model with trackpad-style input; it
is approved and not yet implemented.** Sections marked *Superseded by §11* describe
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
   Screen icon). The page is paired with the Mac once, using a QR code or a pairing code.
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

### D6. Authentication: a single pairing secret
- On first launch the Mac app generates **32 random bytes** (`SecRandomCopyBytes`),
  encoded as base64url. This is the pairing secret. It is stored in the **Keychain**
  (generic password, service `mac-window-remote`). It is never written to logs.
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
    link to Pair.
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
- **Menu:**
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
     title (App — Title), a **Fit** button, and a connection dot.
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
auth, or auth timeout).

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
| `PairingSecret.swift` | Keychain get/create/reset, constant-time compare |
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
4. Run `tailscale serve --bg http://127.0.0.1:8765` once, and enter
   `https://<your-mac>.<tailnet>.ts.net` as the iPhone URL in Settings.
5. On the iPhone, scan the QR code from **Pair iPhone…**. Optionally, use Share →
   **Add to Home Screen**, open it, and paste the pairing code once.
6. Keep the Mac unlocked while using it remotely. Confirm macOS's periodic Screen
   Recording prompts when they appear.

## 9. Security summary
- The server is reachable only through loopback, so only `tailscale serve` (the tailnet)
  and local processes can reach it.
- All functionality requires the 256-bit pairing secret, and there is one client at a
  time.
- The secret is kept in the Mac Keychain and the phone's `localStorage`. It is carried
  in a URL fragment only during QR pairing. It is never logged.
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
- **D6 Keychain access after a rebuild.** With the ad-hoc signature (D17), a rebuilt binary
  is a new code identity. Reading the existing Keychain item then waits on a macOS "allow
  access" prompt. The app reads the secret off the main thread, so the menu stays usable
  and shows "Waiting for Keychain access…". The server starts after the read. Signing with
  `CODESIGN_IDENTITY` avoids the prompt, just as it keeps the TCC grants.
- **D17 toolchain.** `scripts/build-app.sh` runs `xcrun swift`, so it uses the selected
  Xcode, or `DEVELOPER_DIR` when that is set, rather than whatever `swift` comes first in
  `PATH`. The current dependency graph (swift-crypto 5 through swift-nio-ssl) needs Swift
  6.3 or later to parse its manifest.
- **Slice 1 key names.** The phone sends only `Enter` and `Backspace` in slice 1, and the
  text chunker sends `Tab` for `\t`. `KeyMap` holds just those three. The server rejects
  other names and any non-empty `mods` with `bad_request`. The full §4.3 table arrives with
  the key bar in slice 4.
- **Slice 1 message size.** `/ws` accepts messages up to 1 MiB in slice 1. D12 raises the
  limit to 26 MiB when image upload arrives in slice 3. Binary client messages get
  `bad_request` until then.
