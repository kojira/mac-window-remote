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
| Gesture | Effect | Slice |
|---|---|---|
| 2-finger pinch / pan | Zoom (1× = fit to screen, up to 8×) and pan the view on the phone only | 1 |
| 1-finger tap | Left click at the point | 1 |
| 2nd tap within 300 ms and 20 px | Double-click (sent as `pointer doubleClick`) | 1 |
| 1-finger drag, starting before 400 ms | Scroll the window (`scroll`, throttled to one message per animation frame) | 1 |
| 1-finger hold 400 ms, then release without moving | Right-click | 4 |
| 1-finger hold 400 ms, then move | Left-button drag (`pointer down/move/up`) | 4 |

A tap moves at most 10 px and lasts at most 400 ms. The Fit button resets zoom and pan.

