# mac-window-remote — Design (v0.2)

Status: **Slice 1 implemented, then replaced by revision 2 (§11: WebRTC video and
trackpad-style input), which is implemented and awaits acceptance on a real iPhone.
§12 (D32) replaces pairing with the Mac owner's Tailscale identity. §13 (D33) replaces the
viewer's top bar with a bottom bar that has quick-switch slots. §14 (D34) replaces the
D13 key bar with a key panel. §15 (D35) adds resizing the Mac window to fit the phone.
§16 (D36) adds pasting the iPhone clipboard or an image; §17 (D37) adds ⌘F1 and ⌘Tab keys (§27 D48 swaps ⌘Tab for ⌘W).
§19 (D39) plays the Mac's audio on the iPhone; §20 (D40) adds an Apps launcher tab. §23 (D45) adds
a desktop browser's mouse and keyboard.** Sections marked *Superseded by §11* describe
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

- ~~Audio streaming.~~ §19 (D39) adds Mac → iPhone audio. Microphone audio stays out of
  scope.
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
> *Amended by §16 D36:* 📋 Paste in the key panel always pastes into the viewed window; no
> preview or Copy to Mac. The text travels as a binary WebSocket message.
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
> *Amended by §16 D36:* 🖼 Image in the key panel pastes the path into the viewed window; no
> `action`. The image is sent in 256 KiB chunks; the server's frame limit stays small. No
> "Open uploads folder" menu item yet.
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
  > *Amended (user decision: avoid constant polling):* permissions are checked at launch,
  > when a phone session starts, when the menu bar menu opens, and every 2 s only while
  > the Setup & Permissions window is open. There is no always-on poll.
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
> *Amended by §16 D36:* the normal layer has a third row, 📋 Paste and 🖼 Image.
> *Amended by §17 D37:* that third row starts with ⌘F1 and ⌘Tab.
> *Amended by §21 D41:* that third row is ⌘F1, ⌘Tab, space, ⏎, ⋯ (Paste, Image, ⌘Q menu).
- **Why (user request, with a reference image):** the iOS keyboard cannot type Esc, Tab,
  arrows, F-keys, or ⌘/⌃/⌥ shortcuts such as ⌘C, ⌘V, and ⌃C. The panel gives those keys
  large targets. Custom buttons (D13) are not part of this step.
- **Entry.** ⌨︎ in the bottom bar (D33) toggles the key panel; ⌨︎ is highlighted while
  the panel is open. It no longer opens the iOS keyboard directly; the panel's **text**
  key does. Closing the panel also hides the iOS keyboard, turns every modifier off
  (including locked ones), and returns to the normal layer; leaving the viewer closes
  the panel. So modifiers only ever apply while the panel is visible.
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
  then after 400 ms about 15 per second (every 66 ms) until the finger lifts (or the
  touch is cancelled, or the page is hidden). A touch stays captured by the key it
  started on, so sliding off does not stop the repeat. The modifiers active at the press
  apply to every repeat. Other keys send once on press.
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

## 15. Fit the Mac window to the phone (user decision)

### D35. A toggle that resizes the viewed window to the phone's aspect ratio, with restore
- **Why (user request):** a wide Mac window shown on a portrait phone is tiny. Resizing
  the window itself to the phone's shape uses the whole screen without zooming and panning.
- **Button.** The bottom bar gets **📱** (accessible label "Fit window to phone"; while
  active "Restore window size") right after **Fit**. Order: ‹, slots, Fit, 📱, ⌨︎. It is
  hidden while typing, like the slots and Fit (D33). It is highlighted (as ⌨︎ is) while the
  viewed window is fitted.
  - Tap while not active: send `window.fitPhone` with `aspect` = the stage's
    `clientWidth / clientHeight`. The stage is the visible video area: the screen inside
    the safe area, minus the bottom bar and, when open, the key panel (D33, D34).
  - Tap while active: send `window.restore`.
  - The highlight follows the Mac's `window.fit` reply, not the tap.
- **Phone state.** A `Map` windowId → fitted, in memory only (a page reload forgets it; the
  Mac still restores correctly, see below). Switching windows with the slots or the list
  keeps each window's state, and the button shows the state of the viewed window. Phone
  rotation or opening the key panel while fitted does **not** resize again; to refit, the
  user taps twice (restore, then fit). A fit for a window the Mac already fitted (e.g.
  after a page reload lost the phone state) is accepted and keeps the original frame.
- **Protocol** (`control` data channel, D22/D28), client → server:
  ```jsonc
  {"t":"window.fitPhone","aspect":0.4615}   // width / height of the visible video area
  {"t":"window.restore"}
  ```
  Server → client:
  ```jsonc
  {"t":"window.fit","windowId":1234,"state":"fitted|restored","clamped":false}
  {"t":"error","code":"window_not_resizable|window_fullscreen|window_not_fitted|window_not_found|permission_accessibility","message":"…"}
  ```
  - `aspect` must be a finite number in [0.2, 5]; otherwise `bad_request`. Both apply to
    the window being viewed (the input target); when nothing is viewed the reply is
    `window_not_found`. Both are `bad_request` on the WebSocket (wrong channel).
  - `windowId` in the reply tells the phone which window's state to update, because the
    user may switch windows before the reply arrives.
- **Mac: fit** (Accessibility API on the target window, no private APIs):
  1. Accessibility permission is required (`permission_accessibility`).
  2. Find the AX window of the viewed window's app whose frame matches the CG bounds, as
     the focuser does (D8/D25). None found: `window_not_resizable`.
  3. `AXFullScreen` true: `window_fullscreen`; nothing is touched.
  4. `AXSize` not settable: `window_not_resizable`; nothing is touched.
  5. **Screen:** convert every `NSScreen.frame` and `visibleFrame` (AppKit, bottom-left
     origin, the primary screen at 0,0) to the AX/CG global space (top-left origin of the
     primary screen): `y' = primaryHeight − (y + height)`. The window's screen is the one
     whose frame has the largest intersection with the window's AX frame (the primary
     screen if none intersects). The target area is that screen's visible frame (no menu
     bar, no Dock).
  6. **Target rect:** the largest size with the requested aspect inside the visible frame,
     each side rounded down to whole points, centered in the visible frame (origin rounded
     down to whole points).
  7. **Saved frame:** if the window has no saved frame yet, its current AX frame is saved
     (in memory, keyed by windowId, for the process lifetime). A fit while already fitted
     (e.g. after rotation) keeps the first saved frame.
  8. Set `AXPosition` to the target origin, then `AXSize`, then read `AXSize` back. The app
     may clamp it (minimum/maximum size, fixed width). The window is then re-centered in
     the visible frame with its actual size (if it is larger than the visible frame, its
     top-left goes to the visible frame's top-left, so the title bar stays reachable).
     `clamped` is true when the actual size differs from the target by more than 1 pt in
     either dimension.
  9. If setting `AXSize` fails, the position is set back, a frame saved by this request is
     forgotten, and the reply is `window_not_resizable`.
- **Mac: restore.** No saved frame for the viewed window: `window_not_fitted`. Fullscreen:
  `window_fullscreen` (the saved frame is kept). Otherwise set `AXPosition`, `AXSize`,
  then `AXPosition` again to the saved frame (the second position covers apps that move
  the window when its size changes), read back the size, forget the saved frame, and reply
  `restored` with `clamped` as above.
- **Capture follows the new size** with no new code: the 500 ms bounds poll (D4) sees the
  size change and calls `stream.updateConfiguration`; the encoder follows (D21) and the
  `<video>` intrinsic size changes. On a `window.fit` reply for the viewed window the
  phone fits the view (zoom 1) and fits again at the next intrinsic size change, so the
  resized window fills the stage.
- **Phone toasts:** a `window.fit` with `clamped: true` shows "The app limits this
  window's size" (fitted) or "The app limited the restored size" (restored);
  `window_not_resizable` "This window can't be resized";
  `window_fullscreen` "Full-screen windows can't be resized"; `window_not_fitted` clears
  the button's state (the Mac forgot, e.g. after it restarted) and shows "Window size was
  already restored".
- **Non-goals:** persisting saved frames across Mac app restarts; auto-refit on rotation
  or key panel changes; restoring automatically when the viewer closes; windows closed
  while fitted keep a stale in-memory entry until the app quits (a few bytes).
- **Source changes:** `Protocol.swift` (`window.fitPhone`, `window.restore`, `window.fit`,
  error codes), `Session.swift`, `MacBackend.swift`, `WindowFit.swift` (new: pure rect math
  and saved-frame bookkeeping), `WindowResizer.swift` (new: AX read/write),
  `WindowFocuser.swift` (the AX window lookup is shared); `web/index.html`,
  `web/style.css`, `web/app.js`, `web/viewer.js` (fit on the next size).

### D35 acceptance criteria
On a real iPhone against the real Mac:
1. 📱 sits between Fit and ⌨︎ in portrait and landscape; it is hidden while typing.
2. In portrait, tapping 📱 on a wide window makes the Mac window tall and narrow, centered
   on its screen, inside the menu bar and Dock; the phone shows it filling the stage
   within about a second; 📱 is highlighted.
3. Tapping 📱 again puts the window back at its original size and position; the highlight
   goes away; the view re-fits.
4. With the key panel open, a fit uses the smaller area above the panel.
5. Fitted, rotate to landscape: nothing resizes. Tap (restore) then tap (fit): the window
   takes the landscape shape; restore still returns the original frame from before the
   first fit.
6. Fit window A, switch to B with a slot: 📱 is not highlighted; back to A: highlighted,
   and restore works.
7. A window on a second display is fitted on that display.
8. A non-resizable window (e.g. a fixed-size panel) shows "This window can't be resized";
   a window with a minimum size is fitted as close as possible and centered; a full-screen
   window shows "Full-screen windows can't be resized" and is not touched.
9. *Unit:* aspect-fit rect (wide and tall aspects, whole-point rounding, centering, a
   visible frame with a non-zero origin), AppKit → AX conversion and screen choice for a
   screen left of and above the primary screen, re-centering of a clamped size,
   `window.fitPhone`/`window.restore` decoding (range 0.2–5, missing aspect, wrong
   channel), `window.fit` encoding, and saved-frame bookkeeping (first fit saves, second
   keeps, restore forgets, a failed first fit forgets).

## 16. Paste the iPhone clipboard or an image into the window (user decision; amends D11, D12)

### D36. 📋 Paste and 🖼 Image in the key panel
> *Amended by §22 D42:* 📎 File uploads any file the same way and pastes its path.
> *Amended by §17 D37:* the third row is ⌘F1, ⌘Tab, 📋 Paste, 🖼 Image, two columns each.
> *Amended by §21 D41:* 📋 Paste and 🖼 Image moved into the ⋯ menu; they still act on touch end.
- **Why (user request):** "paste the iPhone clipboard contents into the text" and "upload an
  image and paste its path". Slices 2 and 3 (D11, D12) are implemented in the current
  architecture (§11–§15), with one default action: the content lands in the focused field of
  the viewed window.
- **Placement (amends D34).** The key panel's normal layer gets a third row with two wide
  keys, each spanning three columns: **📋 Paste** and **🖼 Image**. The first two rows are
  unchanged; the fn layer is unchanged. Both layers now have three rows, so the panel height
  no longer changes when fn is toggled. The keys act on touch end (a user gesture, which the
  clipboard read and the file picker require) and never take focus from the text field.
- **📋 Paste (amends D11).** Inside the tap, `navigator.clipboard.readText()`; iOS shows its
  "Paste" callout, and the user taps it.
  - The text goes to the Mac, which puts it on `NSPasteboard.general` (`clearContents`,
    `setString`), focuses the viewed window through the D25 focus path (raise once if it is
    not frontmost, 80 ms before the keystroke only after a raise), and posts ⌘V. It runs in the
    ordered input pipeline, so it lands after any keys sent before it. The previous Mac
    clipboard is not restored (D11).
  - Toast on success: "Pasted N chars" (N = Unicode code points).
  - If `readText` is missing or rejects (denied, plain HTTP), the **fallback sheet** (D5)
    opens: "Long-press the box, choose Paste, then paste it into the window.", a textarea,
    **Cancel**, and **Paste into window**, which sends the textarea's text the same way.
  - At most 1 MiB of UTF-8. The phone checks first and shows "Text too large (max 1 MiB)";
    the Mac checks again and replies `too_large`. Either way the Mac clipboard is unchanged.
  - D11's preview and "Copy to Mac" (`paste: false`) are dropped: the user asked for paste.
- **🖼 Image (amends D12).** `<input type="file" accept="image/*">` opens inside the tap
  (photo library, camera, Files). The bytes are uploaded, saved as in D12 (type sniffed from
  the magic bytes: PNG, JPEG, HEIC/HEIF, GIF, WebP; at most 25 MiB; directory
  `$TMPDIR/mac-window-remote/uploads/`, mode 0700; name `img-YYYYMMDD-HHMMSS-<4 hex>.<ext>`;
  files older than 24 h deleted at launch and hourly, nothing outside the directory), and the
  **path is pasted into the viewed window** the same way as clipboard text (so the path is
  also left on the Mac clipboard). D12's `action` (`clipboard`/`type`/`none`) is dropped.
  - Toast on success: "Pasted path: …/img-20260101-030405-0a3f.png" (the file name only).
  - Images over 2 × 512 KiB show a sticky toast "Uploading… n%", then "Pasting…" until the
    reply. Input keeps working during an upload.
  - Errors: over 25 MiB "Image too large (max 25 MiB)" (the phone checks `File.size` first and
    sends nothing); not an accepted type "Not a supported image (PNG, JPEG, HEIC, GIF, WebP)".
    Neither leaves a file.
  - Taking a photo with the camera can hide the page, which closes the socket (D15). A picked
    image waits up to 10 s for the reconnect and the resumed view before it is sent.
  - A new pick while an image is still being sent cancels the older one on the phone.
- **Transport (decision).** Both requests are **binary messages on the authenticated `/ws`**
  (§4.1 framing: `[uint32 BE headerLength][header JSON][payload]`), not the `control` data
  channel (amends D22's note). Why: the WebSocket already has the owner check (D32) and a
  simple size limit, and needs no chunk reassembly across SCTP message limits; the data
  channel would need its own framing. Raising the server's max frame to 26 MiB for a single
  image message was rejected: an image would then hold up the socket's pings and signaling
  for as long as it takes to send, and the server would buffer each 26 MiB frame whole.
  Instead images are sent in **256 KiB chunks**, and the phone keeps at most 512 KiB in the
  socket's send buffer, so pings (10 s, D18) and signaling interleave. The server's max
  message and frame size is **1 MiB + 64 KiB** (clipboard text plus framing).
  - Phone → Mac:
    ```jsonc
    // binary: header {"t":"clipboard.paste","id":"c1"} + UTF-8 text (1 byte – 1 MiB)
    // binary: header {"t":"image.chunk","id":"i1","size":834512,"offset":0} + ≤ 256 KiB
    ```
  - Mac → phone on the WebSocket:
    ```jsonc
    {"t":"result","id":"c1","ok":true}
    {"t":"result","id":"i1","ok":true,"path":"/var/folders/…/T/mac-window-remote/uploads/img-20260101-030405-0a3f.png"}
    {"t":"error","id":"i1","code":"too_large|unsupported_type|window_not_found|permission_accessibility|bad_request|internal","message":"…"}
    ```
  - Validation: header ≤ 1 KiB of JSON; `id` a non-empty string of at most 64 characters;
    clipboard payload non-empty valid UTF-8 ≤ 1 MiB (over: `too_large` with the id); chunk
    `size` > 0, `offset` ≥ 0, payload 1 byte – 256 KiB, `offset + payload ≤ size`; anything
    else `bad_request`.
  - Assembly on the Mac: chunks arrive in order on the socket. Offset 0 starts an upload
    (replacing an unfinished one); it is checked at once: `size` > 25 MiB is `too_large`, and
    the first chunk's magic bytes decide the type (`unsupported_type`). A chunk whose offset
    is not the bytes received so far, or of another id, is `bad_request`. After a rejection
    the rest of that upload's chunks are ignored. When `size` bytes have arrived the file is
    written (never overwriting), then the path is pasted. An upload started while no window
    is viewed is `window_not_found`.
  - One reply per request: `result` after ⌘V was posted, or `error`. A paste for a window
    that is no longer viewed replies `window_not_found`. The socket closing drops pending
    requests; the phone shows "Upload interrupted — try again".
- **Logging:** byte counts and types only; never the text or the path.
- **"Open uploads folder" menu item (D12):** skipped. The path is pasted, so the folder is
  reachable from it; the item can be added later if wanted.
- **Source changes:** `Protocol.swift` (`BinaryClientMessage`, `result`), `Uploads.swift`
  (new: `ImageType` sniffing, `ImageUploadAssembler`, `UploadStore` save and cleanup),
  `Session.swift` (binary messages), `InputPipeline.swift` and `MacBackend.swift` (`paste`
  input: pasteboard + ⌘V with a reply), `Server.swift` (max message size), `App.swift`
  (cleanup at launch and hourly); `web/upload.js` (new: framing and limits),
  `web/keypanel.js` (third row), `web/app.js` (clipboard read, fallback sheet, image upload,
  replies, sticky progress toast), `web/index.html`, `web/style.css`.

### D36 acceptance criteria
On a real iPhone against the real Mac:
1. The key panel's normal layer shows the unchanged 2×6 keys and a third row with 📋 Paste
   and 🖼 Image; the fn layer is unchanged; the video re-fits above the panel.
2. Copy multi-line Japanese text on the iPhone, focus a text field in the viewed Mac window,
   tap 📋, and tap iOS's Paste callout: the same text (with newlines) appears in the field;
   the toast says "Pasted N chars". The Mac clipboard holds the text.
3. If the clipboard read is refused, the sheet appears; long-press → Paste, then
   **Paste into window** pastes the same way.
4. Text over 1 MiB shows "Text too large (max 1 MiB)", and the Mac clipboard is unchanged.
5. 🖼 → pick a photo: the path `/var/folders/…/mac-window-remote/uploads/img-….jpg` is pasted
   into the focused field, the toast shows "Pasted path: …/img-….jpg", and the file opens as
   an image. A photo taken with the camera works the same.
6. A large image (several MiB) shows "Uploading… n%" rising to 100 %, and the cursor and keys
   still work during the upload.
7. A non-image file from Files shows "Not a supported image …"; a file over 25 MiB shows
   "Image too large (max 25 MiB)"; neither leaves a file in the uploads directory.
8. *Unit:* magic-byte sniffing for each accepted type and rejection of others; chunk assembly
   (in order, gap, other id, ignored after a rejection, 25 MiB limit); file name format;
   save with mode 0700; cleanup (older than 24 h deleted, newer kept, nothing outside the
   directory, subdirectories and links skipped); binary message decoding (framing, header,
   id, 1 MiB clipboard limit, chunk bounds); `result` encoding; phone-side framing, 1 MiB
   UTF-8 limit, and chunk coverage.

## 17. One-tap ⌘F1 and ⌘Tab (user decision; amends D34, D36)

### D37. Combo keys ⌘F1 and ⌘Tab in the key panel's third row
> *Amended by §21 D41:* the third row is ⌘F1, ⌘Tab, space (two columns), ⏎, ⋯.
- **Why (user request):** one tap for ⌘F1 and ⌘Tab instead of ⌘ then fn then F1 or ⌘ then tab.
  This is not the general custom-button editor (D13); the two keys are fixed.
- **Placement (amends D36).** The normal layer's third row is four keys of two columns each:
  **⌘F1**, **⌘Tab**, **📋 Paste**, **🖼 Image**. Rows one and two, the fn layer, and the
  panel height are unchanged.
- **Behavior.** A combo key acts like any other panel key (D34): it sends on press, shows the
  pressed highlight, never takes focus, and does not auto-repeat. It sends the existing `key`
  message with its own modifier added to the active ones: `{"t":"key","key":"F1","mods":["cmd"]}`
  and `{"t":"key","key":"Tab","mods":["cmd"]}`. Active modifiers are merged, each once, in
  the order cmd, ctrl, opt, shift (armed ⇧ then ⌘Tab sends `["cmd","shift"]`; a locked ⌘
  does not repeat `cmd`). Armed modifiers then disarm; locked ones stay.
- **Mac side: unchanged** (*amended by §18 D38:* F-keys and navigation keys now also carry
  the Fn flag, which ⌘F1 needs to match the system shortcut). The D34 combo posting (`.hidSystemState` source, `.cghidEventTap`)
  posts ⌘ down (a `flagsChanged` with the command flag), Tab down and up with the command
  flag, then ⌘ up. Events posted at the HID tap pass through the window server like hardware
  input, so system hot keys such as ⌘Tab act. A ⌘Tab whose ⌘ is released at once is a quick
  switch: the app switcher does not stay on screen, and the most recently used other app
  comes to the front. Holding ⌘ to step through the switcher is not possible (each tap is one
  full combo).
  - The phone keeps showing the viewed window (the stream follows the window, not the front
    app), and the next input raises the viewed window again (D25). So ⌘Tab's effect is seen
    on the Mac screen, not on the phone, unless the viewed window is the one brought forward.
    *Amended by §18 D38:* the viewer now follows the window that ⌘Tab or ⌘F1 brings forward.
- **Source changes:** `web/modifiers.js` (`mergeMods`), `web/keypanel.js` (two keys and the
  merge), `web/style.css` (four keys per row).

### D37 acceptance criteria
On a real iPhone against the real Mac:
1. The normal layer's third row shows ⌘F1, ⌘Tab, 📋 Paste, 🖼 Image with legible labels in
   portrait and landscape; the fn layer is unchanged; the panel height is unchanged.
2. ⌘Tab brings the most recently used other app to the front on the Mac.
3. ⌘F1 sends ⌘F1 (e.g. with the default macOS shortcut, mirror displays toggles if a second
   display is attached, or the app's own ⌘F1 action fires).
4. ⇧ then ⌘Tab sends ⌘⇧Tab, and ⇧ disarms; a locked ⌘ stays locked after ⌘Tab.
5. Holding ⌘Tab sends it once (no repeat); the key highlights while pressed.
6. 📋 Paste and 🖼 Image still work as in D36.
7. *Unit:* merging a combo key's mods with armed and locked modifiers.

## 18. The viewer follows ⌘Tab and window cycling (user decision; amends D37)

### D38. After ⌘Tab, ⌘F1, or ⌘` the view switches to the window that came to the front
- **Why (user request, after using D37 on the iPhone):** ⌘Tab brought another app forward on
  the Mac, but the phone kept showing the old window, and the next tap raised the old window
  again (D25), undoing the switch.
- **Amendment (user QC of ⌘F1, approved):** ⌘F1 did nothing at all. The user's "Move focus to
  next window" shortcut is ⌘F1, and macOS registers such shortcuts with the Fn flag
  (`kCGEventFlagMaskSecondaryFn`), which a real Apple keyboard sets on F1–F12 and on the
  navigation keys; our events lacked it, so the shortcut never matched.
  - **Fix (all keys, D9/D34):** the key's own down and up events carry the flags a real
    keyboard sets, in addition to the modifiers: Fn on F1–F12, Home, End, PageUp, PageDown,
    forward Delete (and Help); Fn plus NumericPad on the four arrows. Modifier key events
    are unchanged (`KeyMap.hardwareFlags`).
  - ⌘F1 (and ⌘`, the macOS default for the same action) switches windows within the front
    app, so the view follows it like ⌘Tab.
- **Trigger.** A `key` message with `cmd` in `mods` whose key is `Tab`, `F1`, or `` ` ``
  (so ⌘Tab, ⌘⇧Tab, ⌘F1, ⌘⇧F1, ⌘`, ⌘⇧`, from the combo keys or from ⌘ then the key), while a
  window is viewed (`isWindowSwitch`). It is posted through the ordered input pipeline as
  before (D25, D34). Nothing else changes for other keys.
  - Before posting it, the viewed window is brought to the front once (D25) and, if a raise
    happened, the combo waits the same 80 ms as a click, so the switch starts from the viewed
    window and not from whatever was in front before.
- **Mac: find the new window** (after the combo was posted without error):
  1. Take the pickable window ids once (`WindowCatalog.shareableWindows`, the same filter as
     the window list, which also excludes the Mac app's own windows).
  2. Every 25 ms for at most 1 s: read the front app's pid
     (`NSWorkspace.shared.frontmostApplication`) and the on-screen window order
     (`CGWindowListCopyWindowInfo`, on-screen only, no desktop elements, front to back), and
     pick the front app's frontmost window: the first entry owned by that pid that is
     layer 0, at least 50 × 50 pt, and pickable. The switch is seen when that window is not
     the viewed window. This covers both cases: ⌘Tab (another app comes forward, so its
     window differs) and ⌘F1 / ⌘` (the front app stays; another of its windows comes
     forward). Comparing window ids, not app pids, is what makes the same-app case work.
  3. Timeout (e.g. Finder with only the desktop, an app whose windows are all minimized or on
     another Space, a single-window app on ⌘F1): nothing happens (the view stays).
  4. If the phone switched windows meanwhile (a slot or the list), or viewing stopped, or the
     session closed, nothing happens.
- **Mac: switch.** Send `{"t":"view.switched","windowId":…,"app":"…","title":"…"}` on the
  WebSocket, then switch the capture exactly as `view.start` does (D18, D33): the old capture
  stops, the new one starts on the same capturer and track (no renegotiation), and
  `view.state` `starting`/`streaming` follow for the new id. The input target becomes the new
  window, so the next input does not raise the old window (D25). The menu bar shows the new
  window.
- **Phone: on `view.switched`** (ignored unless the viewer is shown and a well-formed
  `windowId` differs from the viewed one): the viewed window (the `mwr.window` session
  storage entry, D33) becomes `{id, app, title}` from the message; the video is cleared and
  waits for the new window's first frame (as a slot switch does: fit on the new size, D21);
  the slot highlight and 📱 state follow the new window (D33, D35); the window list is
  refreshed, which re-resolves the slots and requests thumbnails. No toast when the view
  stays; no other UI changes. (Unchanged by the amendment.)
- **Non-goals:** following switches made on the Mac itself (keyboard or mouse there);
  reading the user's own shortcut settings (a remapped "Move focus to next window" other than
  ⌘F1/⌘` is not followed); following other shortcuts that change the front window.
- **Source changes:** `KeyMap.swift` (`hardwareFlags`, used by `strokes`), `Protocol.swift`
  (`view.switched`), `Session.swift` (follow after the combo), `MacBackend.swift` (poll for
  the switch, 80 ms after a raise), `WindowCatalog.swift` (on-screen order, switched window
  selection), `InputPipeline.swift` (`isWindowSwitch`); `web/app.js`, `web/slots.js`
  (`decodeViewSwitched`).

### D38 acceptance criteria
On a real iPhone against the real Mac:
1. Viewing window A of app X, tap ⌘Tab: the Mac brings the most recently used other app Y
   forward, and within about a second the phone shows Y's frontmost window without
   "Connecting video…"; the view fits the new window.
2. Tap on the video after that: the tap goes to Y's window; X's window is not raised.
3. ⇧ then ⌘Tab (⌘⇧Tab) behaves the same with the app the reverse switch brings forward.
4. If Y's window is in a slot, that slot becomes highlighted; 📱 shows Y's window's state;
   thumbnails refresh.
5. If Y has no pickable window (e.g. Finder with only the desktop), the phone keeps showing
   A and no error appears.
6. Viewing window A of an app with two or more windows, tap ⌘F1: the Mac brings the app's
   next window B forward (the system "Move focus to next window" shortcut now fires), and
   within about a second the phone shows B; the next tap goes to B, A is not raised.
   ⌘ then ` behaves the same. With a single-window app, ⌘F1 changes nothing on the phone.
7. F-keys, arrows, Home/End/PageUp/PageDown and forward Delete still act as before in apps
   (e.g. arrows move the cursor, ⇧+arrows select); 📋 Paste, 🖼 Image, and slot switching are
   unchanged.
8. *Unit:* the Fn/NumericPad flags per key and on a combo's events; switched window
   selection from a sample on-screen order (front to back, layer 0, minimum size, pickable
   ids, front app's pid; same-app and other-app switches; not yet switched; none);
   `isWindowSwitch`; `view.switched` encoding and the phone's decoding.

## 19. Mac audio on the iPhone (user decision; amends §1 non-goals, D21, D22, D33)

### D39. 🔊 plays the Mac's sound only on the iPhone: Off → App → All
- **Why (user request):** hear the viewed app (a video, a call, a notification sound) on the
  iPhone without it also playing out of the Mac's speakers.
- **Modes.** A 🔊 button in the bottom bar cycles **Off → App → All → Off**:
  - **Off** (🔇, default): no audio; the Mac sounds as usual.
  - **App** (🔊 App): the app that owns the viewed window, with its helper processes.
  - **All** (🔊 All): every process on the Mac except Mac Window Remote itself.
  While a phone is connected and the mode is not Off, **the tapped audio is muted on the Mac**
  and plays only on the iPhone. Off, a dropped or failed connection, the session being
  replaced (4002), the page closing or going to the background (D15), or a tap failure all
  tear the tap down, and the Mac is audible again at once.
- **Mac: capture (Core Audio process tap, macOS 14.2+).** `SystemAudioTap` owns one
  `CATapDescription` tap, a private aggregate device that contains it, and an IOProc:
  - All: `CATapDescription(stereoGlobalTapButExcludeProcesses: [own process object])`
    (empty if our process has no audio object; we never play audio).
  - App: `CATapDescription(stereoMixdownOfProcesses:)` of the viewed app's process objects:
    every Core Audio process object whose pid is the window's pid, or whose bundle ID equals
    the app's bundle ID or starts with `bundleID + "."` (Chrome's `…helper`,
    `…helper.Renderer`, Electron helpers). Never our own process. For Safari
    (`com.apple.Safari`, `com.apple.SafariTechnologyPreview`) also `com.apple.WebKit.GPU`
    (below). An app that has not used audio yet has no process object: the tap is not
    created until one appears.
  - `isPrivate = true`, `muteBehavior = .mutedWhenTapped`: the tapped processes are silent
    on the Mac only while our IOProc reads the tap. Stopping the IOProc, destroying the tap,
    or our process exiting (the tap and aggregate are private) makes the Mac audible again.
  - Aggregate: private, not stacked, the tap with drift compensation, clocked by the default
    output device as a sub-device — unless that device also has input streams (a headset),
    in which case the aggregate holds the tap alone, so no microphone is ever opened.
  - Teardown order: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`,
    `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`.
  - **App mode follows the view.** On every started capture (the list, a slot, ⌘Tab/⌘F1/⌘`
    following, D33, D38) the session sets the target to the new window's pid. Another
    window of the same app changes nothing. Another app, or new or exited helper processes
    (a listener on `kAudioHardwarePropertyProcessObjectList`), rewrite the process list of
    the existing tap through `kAudioTapPropertyDescription`, without a gap; if that fails,
    the tap is rebuilt. With no viewed window (the list), App mode has no tap: nothing is
    muted.
  - **Output device change** (a listener on `kAudioHardwarePropertyDefaultOutputDevice`,
    e.g. headphones plugged in): the tap and aggregate are rebuilt.
  - All Core Audio calls run on one serial queue; the tap is created on first use, so the
    app touches Core Audio only after the phone asks for audio.
- **Mac: conversion.** The IOProc reads the tap's Float32 buffers (the tap's streams are the
  last buffers of the aggregate's input list), averages the channels to **mono**, converts
  the aggregate's rate to **48 kHz** (`AVAudioConverter`, only if it differs), converts to
  Int16 (clipped), and cuts exact **480-frame (10 ms) chunks** (`AudioChunker`).
  Stereo is out of scope: the WebRTC capture pipeline in this build downmixes to mono anyway
  (measured in the research spike).
- **Mac: WebRTC.** The factory is created with `initWithEncoderFactory:decoderFactory:audioDevice:`
  and our `TapAudioDevice` (an `RTCAudioDevice`: 48 kHz, 1 channel, 10 ms). It never opens a
  microphone or speaker: recording is fed by the tap through `deliverRecordedData`, and
  playout does nothing, so the Mac never plays WebRTC audio (and never asks for microphone
  access). Chunks are dropped unless WebRTC is recording. Before a rebuilt tap delivers from
  its new IO thread, `notifyAudioInputInterrupted` is called.
  - `RTCAudioDevice.h` is not in the macOS slice of stasel/WebRTC 153.0.0, although the
    binary implements it. The target `WebRTCAudioDevice` vendors the header **verbatim**
    from the iOS slice of the same version, with its BSD license
    (`mac/Sources/WebRTCAudioDevice/LICENSE`). **Pinned:** re-copy it when WebRTC is bumped.
  - One audio source and track (`trackId "audio"`) with echo cancellation, gain control,
    noise suppression, and the high-pass filter off. `RTCPeer.answer` sets the phone's audio
    transceiver to `sendonly` with that track (a page without one still works). Opus, as
    negotiated by default.
- **When the tap runs** (`AudioTarget.desired`): mode ≠ Off, the peer connection is
  `connected`, and in App mode a window is viewed (capture started). The session applies it
  on every change of the mode, the peer state, or the viewed pid; `disconnected` stops the
  tap at once (the Mac is audible during a reconnect), `connected` again restarts it.
  Session teardown closes the peer, which stops it. The mode is not stored on the Mac.
- **Phone.**
  - `rtc.js` adds `addTransceiver('audio', {direction: 'recvonly'})` after the video one.
  - A separate `<audio id="audio" playsinline>` plays it; `<video>` stays `muted` (its
    autoplay must not depend on a gesture). The element has one `MediaStream` for the page's
    life; each new connection swaps the track in it instead of replacing `srcObject`, so the
    element stays unlocked after the first tap.
  - 🔊 is a tap handler: it cycles the mode, stores it (`localStorage['mwr.audio']` =
    `off|app|all`), sends `{"t":"audio","mode":…}` on `control`, and calls `play()` (or
    `pause()` for Off) inside the tap, which unlocks audio on iOS. `navigator.audioSession.type
    = 'playback'` when available.
  - After a reload with a stored mode ≠ Off (or if iOS refuses `play()` after a reconnect),
    the button shows the mode with an **orange dot** until iOS allows playback; the next touch
    anywhere (e.g. the first trackpad touch) calls `play()`. A tap on 🔊 while the dot is shown only enables sound, it does not change the
    mode.
  - Every `onReady` (a new peer connection) re-sends the mode. The Mac echoes each request
    with `audio.state`; the phone takes the echoed mode only when no newer request is
    unanswered (fast taps do not flicker).
  - Placement: after 📱, before ⌨︎; 40 pt wide, icon over a small "Off/App/All" label; blue
    while on. Hidden while typing, like the slots, Fit, and 📱.
- **Protocol** (on `control`, like other input):
  ```jsonc
  // phone → Mac
  {"t":"audio","mode":"off"|"app"|"all"}            // other or missing mode: bad_request
  // Mac → phone
  {"t":"audio.state","mode":"off"|"app"|"all"}      // echo; "off" after audio_unavailable
  {"t":"error","code":"audio_unavailable","message":"Mac audio is not available on this Mac"}
  {"t":"error","code":"permission_audio_capture","message":"No audio: allow audio capture in System Settings › Privacy & Security"}
  ```
  The phone shows both errors as a toast.
- **Permission (TCC).** `NSAudioCaptureUsageDescription` is in `Info.plist`. macOS asks the
  first time the tap is read ("System Audio Recording"); it is separate from Screen
  Recording and is listed in System Settings › Privacy & Security › Screen & System Audio
  Recording. There is no public preflight API. When denied, the tap still works but yields
  silence. **Silence detection:** once a second the Mac checks whether any tapped process
  reports `kAudioProcessPropertyIsRunningOutput`; if the tap delivered only exact zeros
  since it started while a tapped process was playing, for 4 checks in a row, it sends
  `permission_audio_capture` once per tap. Real audio seen once disables the check for that
  tap. An ad-hoc re-signed build loses the grant like Screen Recording (D17).
- **Failures.** macOS before 14.2, or a tap/aggregate/IOProc that cannot be created:
  everything built is torn down, the mode becomes Off, and the phone gets
  `audio_unavailable` and `audio.state off`.
- **Known limitations.**
  - **Safari and WebKit apps:** web audio plays in the shared `com.apple.WebKit.GPU`
    process, which has no Safari bundle-ID prefix. App mode on Safari therefore also taps
    (and mutes) WebKit.GPU, which carries the audio of other WebKit-based apps (e.g. Mail,
    other WKWebView apps) too. Other WKWebView apps are not given WebKit.GPU and may be
    silent in App mode; All mode always works.
  - Mono only; stereo is not sent.
  - With an output device that also has inputs (a Bluetooth or USB headset), the aggregate
    holds only the tap, so the headset's microphone is not opened. That tap-only aggregate is
    to be confirmed on the device (acceptance 8); if it yields no callbacks, the design comes
    back here.
  - Audio is not lip-synced to the video explicitly; both paths are low-latency.
  - Sounds the Mac makes itself (system alerts from other processes) follow the mode like
    any process: All mode taps them, App mode does not.
- **Non-goals:** microphone or phone → Mac audio; audio while the page is in the background
  (the connection closes, D15); per-app volume.
- **Source changes:** `Package.swift` (target `WebRTCAudioDevice`), `WebRTCAudioDevice/`
  (vendored header, license), `TapAudioDevice.swift`, `SystemAudioTap.swift`,
  `AudioChunker.swift`, `AudioProcessSelection.swift` (new), `RTCHost.swift` (factory with
  the device, audio track, audio transceiver), `Protocol.swift` (`audio`, `audio.state`,
  error codes), `Session.swift` (mode, target, events), `MacBackend.swift` (`setAudio`),
  `Resources/Info.plist`; `web/audio.js` (new), `web/rtc.js`, `web/app.js`,
  `web/index.html`, `web/style.css`.

### D39 acceptance criteria
On a real iPhone against the real Mac (build signed with the development identity):
1. The bottom bar shows 🔇 Off after 📱. Video, input, slots, and the key panel work as before
   with audio Off, and the Mac never asks for microphone access.
2. Viewing a window of an app that plays sound (e.g. a YouTube tab in Chrome), tap 🔊 once
   (App): the first time, macOS asks to allow Mac Window Remote to record system audio;
   after Allow, the sound plays on the iPhone within about a second and **not** from the
   Mac's speakers. Other apps still sound on the Mac.
3. Tap again (All): every Mac sound (another app, a notification) plays on the iPhone and
   none on the Mac. Tap again (Off): the Mac's speakers play again at once; the phone is
   silent.
4. In App mode, switching the view to another app (slot, list, ⌘Tab) moves the audio to the
   new app: the old app is audible on the Mac again, the new one only on the phone. ⌘F1 to
   another window of the same app changes nothing audible.
5. With audio on, going to the window list (App mode: the app is audible on the Mac again),
   locking the phone or switching to another iPhone app, losing the network, or opening the
   page on another device (4002) returns the Mac's sound; coming back resumes the mode
   without another tap (after a reload: the first touch anywhere).
6. Reloading the page keeps the mode (🔊 App/All with an orange dot until the first touch).
7. With System Audio Recording denied, the phone shows "No audio: allow audio capture in
   System Settings › Privacy & Security" within about 5 s of sound playing.
8. Plugging in or switching the Mac's output device while listening keeps the sound on the
   phone (after a short gap) and the Mac silent.
9. Quitting or force-quitting the Mac app while listening makes the Mac audible again.
10. *Unit:* downmix, 48 kHz resampling, Int16 clipping, and 480-frame chunking; process
    selection by pid, bundle ID and prefix, Safari's WebKit.GPU, never our own process; when
    the tap runs (mode, connection, viewed window); `audio` decoding and channel,
    `audio.state` encoding; the phone's stored mode, cycle, labels, and reply handling.

## 20. App launcher with the Dock's apps (user decision)

### D40. An Apps tab on the window list launches or activates an app and views its window
- **Why (user request):** opening an app that has no window yet (or is not running) needed the
  Mac itself; the window list only shows windows that already exist.
- **Phone.** The window list screen (‹) gets a segmented switch at the top: **Windows | Apps**.
  Windows is the existing list, unchanged. Apps is a grid of app icons with the name under
  each (4 columns on an iPhone in portrait, more when wider; large tap targets): the Dock's
  persistent apps in Dock order, then the running regular apps (`activationPolicy ==
  .regular`) that are not in the Dock, in launch order. A running app has a small dot under
  its name, like the Dock. The chosen tab is kept in `sessionStorage` (`mwr.listTab`).
  - Tapping an icon sends `app.open` and shows "Opening <name>…" over the grid (further taps
    replace the pending one). When the Mac answers `view.switched`, the viewer opens on that
    window exactly as after a slot or list pick (D33, D38). When the Mac answers the error
    `app_no_window` (no window within 10 s, e.g. an app that starts without windows, or whose
    windows are all minimized or on another Space), the phone shows the toast "<name> has no
    window" and stays on the grid. The phone also gives up after 12 s on its own.
  - Refresh on the Apps tab re-requests the app list; switching to the tab requests it too.
- **Mac: the app list** (`apps.list` → `apps`). Dock apps come from
  `CFPreferencesCopyAppValue("persistent-apps", "com.apple.dock")`: each tile's
  `tile-data.file-data._CFURLString` (a `file://` URL) is the app bundle. Tiles without that URL,
  non-file URLs, and bundles that do not exist are skipped; duplicates keep the first. Running
  regular apps with a bundle URL follow, minus those already listed and minus this app. Each
  item is `{"id":"…","name":"…","running":true|false}`; `name` is the bundle's display name
  without `.app`.
  - `id` is an opaque, stable token derived from the bundle path (64-bit FNV-1a, hex). The Mac
    keeps the id → bundle URL map of the list it produced last. **Only ids in that map are
    launched or have icons served**; the phone never sends a path. An unknown id gets
    `app_not_found`.
- **Mac: icons.** `GET /apps/icon/<id>.png` (behind the same Tailscale identity middleware as
  every other route, D32) returns the bundle icon (`NSWorkspace.icon(forFile:)`) drawn at
  128 × 128 px as PNG, cached in memory, with `Cache-Control: private, max-age=86400`. Unknown
  id: 404.
- **Mac: open** (`{"t":"app.open","id":"…"}` on the WebSocket). `NSWorkspace.openApplication(at:
  configuration:)` with `activates = true` launches the app, or activates a running one (which,
  like a Dock click, asks it to reopen a window). Then every 250 ms for at most 10 s the Mac
  looks for that pid's frontmost pickable window (the D38 selection:
  `WindowCatalog.frontWindowId` over the on-screen order and `shareableWindows`). Found: the Mac
  sends `view.switched` and starts viewing it as `view.start` does (the D38 switch). Not found:
  `{"t":"error","id":"<app id>","code":"app_no_window",…}`; launch failure: `app_launch_failed`.
  A newer `app.open` cancels the older wait; a `view.start`/`view.stop` meanwhile, or the
  session closing, makes the result be dropped.
- **Non-goals:** Finder/Trash/folder/recent-app Dock tiles; quitting or hiding apps; choosing
  among an app's windows (the list does that); watching the Dock for changes (the list is
  read when requested).
- **Source changes:** `AppCatalog.swift` (new: Dock parsing, merge, ids, allowlist, icons),
  `Protocol.swift` (`apps.list`, `app.open`, `apps`, error codes), `Session.swift`,
  `MacBackend.swift` (`listApps`, `appIcon`, `openApp`), `Server.swift` (icon route);
  `web/apps.js` (new: `apps` decoding), `web/app.js`, `web/index.html`, `web/style.css`.

### D40 acceptance criteria
On a real iPhone against the real Mac:
1. ‹ shows Windows | Apps; Windows is the old list. Apps shows the Dock's apps in Dock order
   with their icons and names, then other running apps; running apps have a dot.
2. Tapping a running app with a window: "Opening <name>…", then within about a second the
   viewer shows that app's front window, and input goes to it.
3. Tapping an app that is not running launches it on the Mac and the viewer shows its first
   window once it appears.
4. An app that opens no window (or whose windows are all minimized) gives "<name> has no
   window" after about 10 s and the grid stays.
5. *Unit:* Dock plist parsing into the ordered, de-duplicated list (missing bundles and
   malformed tiles skipped), running apps appended without duplicates; an unknown or stale id
   is rejected (no URL); `apps.list`/`app.open` decoding and `apps` encoding; the phone's
   `apps` decoding.

## 21. space, ⏎, and a ⋯ menu in the key panel's third row (user decision; amends D36, D37)

### D41. Third row ⌘F1 | ⌘Tab | space | ⏎ | ⋯, with 📋 Paste, 🖼 Image, and ⌘Q in ⋯
> *Amended by §22 D42:* the menu is 📋 Paste, 🖼 Image, 📎 File, ⌘Q.
- **Why (user request):** space and Return with panel modifiers (⇧⏎, ⌘⏎) without opening the
  iOS keyboard, and ⌘Q in one tap.
- **Layout (amends D36, D37).** The normal layer's third row, in six columns: **⌘F1**, **⌘Tab**,
  **space** (two columns), **⏎**, **⋯**. Rows one and two, the fn layer, and the panel height
  are unchanged.
- **space and ⏎** are normal panel keys (D34): they send `Space` and `Enter` (the Mac's
  existing `kVK_Space` and `kVK_Return`, not keypad Enter) on press with the active modifiers
  (armed ones disarm, locked ones stay), never take focus, and auto-repeat like the arrows.
- **⋯** opens a small menu anchored above the panel's right edge, with, top to bottom:
  **📋 Paste**, **🖼 Image** (the D36 actions), and **⌘Q**. ⋯ is highlighted while it is open.
  - Menu items act on touch end, the user gesture that the clipboard read and the file picker
    require (D36), then the menu closes. ⌘Q is a combo key like ⌘F1 (D37): `{"t":"key",
    "key":"q","mods":["cmd"]}` merged with the active modifiers; it does not repeat. It is in
    the menu rather than the row so that a stray tap cannot quit the viewed app.
  - Tapping ⋯ again, touching anywhere outside the menu, closing the panel, toggling fn, or the
    page being hidden closes the menu without running anything. A touch outside also still does
    what it was aimed at (the trackpad is not blocked).
- **Mac side: unchanged** (`Space`, `Enter`, and `q` are already in §4.3).
- **Source changes:** `web/keypanel.js` (row, menu), `web/style.css` (menu popover).

### D41 acceptance criteria
On a real iPhone against the real Mac:
1. The third row shows ⌘F1, ⌘Tab, a wide space, ⏎, ⋯ with legible labels in portrait and
   landscape; the panel height and the fn layer are unchanged.
2. space types a space and ⏎ a Return in the focused field; ⇧ then ⏎ sends ⇧Return and ⇧
   disarms; ⌘ then ⏎ sends ⌘Return. Holding space or ⏎ repeats after about 0.4 s.
3. ⋯ shows 📋 Paste, 🖼 Image, ⌘Q above the panel. 📋 Paste and 🖼 Image work as in D36
   (the iOS Paste callout and the photo picker appear); the menu closes after choosing.
4. ⌘Q quits the viewed app on the Mac.
5. ⋯ again, or a touch on the video, closes the menu without an action; the trackpad still
   works; closing the panel with the menu open leaves no menu on the next open.
6. *Unit:* the third row's keys; space and ⏎ with modifiers and repeat; Paste and Image fire
   from the menu items' touch end (not touch start, not the row); ⌘Q's merged mods; outside
   touch and panel close close the menu.

## 22. Attach any file and paste its path (user decision; amends D36, D41)

### D42. 📎 File in the ⋯ menu
- **Why (user request):** attach any file, not only images, and paste its Mac path.
- **Entry.** The ⋯ menu (D41) is 📋 Paste, 🖼 Image, **📎 File**, ⌘Q. 📎 File opens an
  `<input type="file">` **without** an `accept` filter (iOS offers Files, Photo Library, and
  Take Photo), inside the item's touch end like 🖼 (D36).
- **Transport.** The D36 chunked upload on `/ws`, with `"t":"file.chunk"`; the chunk at offset 0
  also carries `"name"` (the phone's file name, its last 200 code points so the header stays
  under 1 KiB). Same 256 KiB chunks, send-buffer cap, progress toast, reconnect wait, "a newer
  pick cancels the older one", and one `result`/`error` reply as images.
- **Mac.** Any bytes are accepted; nothing is sniffed, opened, or interpreted, only written.
  At most **100 MiB** (the phone checks `File.size` first: "File too large (max 100 MiB)";
  the Mac replies `too_large` too). The file is saved as
  `$TMPDIR/mac-window-remote/uploads/<UUID>/<name>`, the `<UUID>` subdirectory mode 0700, so
  names never collide and the path ends with the real name. `<name>` is sanitized: last
  path component only (`/` and `\` split), control characters removed, leading dots and
  surrounding spaces removed, at most 200 UTF-8 bytes (the extension kept), else `file`.
- **Paste.** Identical to 🖼: the **raw path, unquoted** is pasted (and left on the Mac
  clipboard). A name with spaces therefore needs quoting by the user in a shell; images never
  have spaces, files may. Kept identical on purpose so the two items do not differ.
- **Cleanup (D12).** The hourly/launch cleanup also deletes `<UUID>` subdirectories (whole)
  whose modification time is older than 24 h. Other subdirectories and links stay skipped.
- 🖼 Image is unchanged (sniffed, 25 MiB, `img-…` names).
- **Source changes:** `Uploads.swift` (`maxFileBytes`, `completeFile`, `sanitizedFileName`,
  `saveFile`, cleanup), `Protocol.swift` (`fileChunk`), `Session.swift`; `web/upload.js`
  (`fileChunkMessages`), `web/keypanel.js` (menu item), `web/app.js`, `web/index.html`,
  `web/style.css`.

### D42 acceptance criteria
On a real iPhone against the real Mac:
1. ⋯ shows 📋 Paste, 🖼 Image, 📎 File, ⌘Q; 📎 File opens the iOS picker with Files, Photo
   Library, and Take Photo.
2. Picking `My Report.pdf` from Files pastes
   `/var/folders/…/mac-window-remote/uploads/<UUID>/My Report.pdf` into the focused field; the
   toast says "Pasted path: …/My Report.pdf"; the file has the same bytes.
3. A file over 100 MiB shows "File too large (max 100 MiB)" and sends nothing.
4. 🖼 Image still works as in D36.
5. *Unit:* file name sanitizing; unique `<UUID>` subdirectory per upload; file chunks not
   sniffed, 100 MiB limit; cleanup of old subdirectories; `file.chunk` decoding and the
   name only on the first chunk; 📎 File fires on the menu item's touch end.

### D43. ☰ the viewed app's menu bar
- **Why (user request, Issue #15):** run a menu command of the viewed app (e.g. Format → Font)
  without reaching the Mac's menu bar, which is outside the captured window.
- **Entry.** ☰ in the viewer's bottom bar (between 🔊 and ⌨︎; hidden while typing like 🔊). It
  opens a full-height sheet titled with the app's name, "Loading…" until the Mac replies.
- **Protocol (`/ws`).** Phone → `{"t":"menu.list"}`; Mac → `{"t":"menu","gen","windowId",
  "menus","truncated"}`. Rows are `{"sep":true}` or `{"id","title","enabled","mark"?,
  "shortcut"?,"items"?}`; `mark` is `check`/`mixed`, `id` is the index path (`"3.1.2"`), `gen`
  numbers the listing. Phone → `{"t":"menu.press","id","gen"}`; Mac → `{"t":"menu.pressed","id"}`
  or `error` with that `id`: `menu_stale` (not in the last listing of the still-viewed window,
  or the titles along the path changed), `menu_disabled`, `menu_failed`,
  `permission_accessibility`, `window_not_found`. A failing list is an `error` without `id`:
  `menu_unavailable`, `permission_accessibility`, `window_not_found`.
- **Mac.** Reads the app's `AXMenuBar` (Accessibility) within 3 s, the Apple menu omitted;
  consecutive/leading/trailing separators dropped; submenus followed 4 levels below a
  top-level menu, 500 rows at most, else `truncated`. A press re-walks the live menu bar by
  the path, checks every title along it and that the item is enabled, raises the window as
  before a click (D25), and `AXPress`es it through the input pipeline.
- **Sheet.** One level at a time: ‹ back with the parent's title, ✕ and a tap outside close.
  Rows show ✓/– marks, the title, and the shortcut right-aligned (› for submenus); disabled
  rows are grey and do nothing; separators are gaps. Tapping an enabled leaf closes the sheet
  and sends `menu.press`; an error shows the toast "Couldn't run <title>". Leaving the viewer
  or switching windows closes the sheet; a late listing for another window is ignored.
- **Limits.** Menus the app fills only when opened (e.g. Open Recent, Window lists in some
  apps) arrive empty: "Empty (this menu fills in only when opened on the Mac)". Depth and row
  caps and the 3 s budget cut large menus ("Some items are not shown"). The Apple menu is not
  offered. Only the menu bar; no context menus or status items.
- **Source changes:** `AppMenu.swift`, `AXMenuSource.swift`, `Protocol.swift`, `Session.swift`,
  `MacBackend.swift`, `InputPipeline.swift`; `web/appmenu.js`, `web/app.js`, `web/index.html`,
  `web/style.css`.

### D43 acceptance criteria
On a real iPhone against the real Mac:
1. Viewing TextEdit, ☰ fits in the portrait bottom bar and opens a sheet titled "TextEdit"
   listing File, Edit, Format, View, Window, Help (no Apple menu).
2. Format → Font shows submenus with ›, shortcuts right-aligned, disabled items grey,
   separators, and ✓ on checked items; ‹ goes back a level; ✕ and a tap outside close.
3. Tapping an enabled item (e.g. Format → Make Plain Text) closes the sheet and runs it in
   TextEdit; a failing press shows "Couldn't run <title>".
4. Without Accessibility permission the sheet shows the permission message.
5. *Unit:* tree building (Apple menu omitted, separators, caps, truncation, shortcuts, marks),
   title-verified press, `menu.list`/`menu.press` decoding, stale gen/window rejected; web
   decoding, drill-down, disabled rows, press with `gen`, closing.

## 23. The viewed app's floating and newly opened windows (user decision, Issue #16; amends D4, D25)

### D44. Child windows are shown with the viewed window
- **Why (user request, Issue #16):** plug-in editors and palettes (e.g. Melodyne in Logic Pro)
  and windows the app opens while viewed (Settings, dialogs) are separate windows, so a plain
  window capture never shows them.
- **What is included.** While viewing window W of app P: W; P's on-screen windows at a
  floating layer (0 < layer < 25) at least 60 × 60 pt; and P's normal (layer 0) windows whose
  id did not exist when viewing W started. Those adopted windows stay included while open, even
  behind W. P's other windows that already existed are not included. Children must touch W's
  display.
  Overlays: P's windows at layer 0..<25, at least 8 × 8 pt, in front of W or an included
  window with ≥ 80 % of their area inside its frame and at most half its area, are included at
  any size (Logic Pro draws title-bar buttons as separate 66 × 20 windows over each window).
- **Capture.** With children, the stream uses `SCContentFilter(display:including:)` with W and
  the children, `sourceRect` = union of W and the children's frames clamped to W's display.
  The window list is polled every 0.5 s; a changed child set or area rebuilds the filter
  (`updateContentFilter` + `updateConfiguration`). Without children, the stream is the plain
  window capture exactly as before (D4).
- **Input.** The phone's normalized cursor maps across the composite area, so a tap on a child
  lands at its real screen position. When the frontmost window at the point (layers 0..<20,
  all apps) is P's, the click is posted with no AX raise or re-ordering; P is only activated
  (without raising windows) if it is not frontmost, so the click itself makes its window key
  and front, and an overlay stays clickable. When another app's window covers the point, the
  click focuses the included window under it: the first
  of W and the children containing the point in the front-to-back on-screen window list
  (`CGWindowListCopyWindowInfo(.optionOnScreenOnly)`), skipping every other window (other apps,
  the Dock's and Notification Center's transparent full-screen windows). A click on a child
  never raises W over it. A normal target is left alone when it is already the front normal
  window; a floating one when its app is frontmost and it is the focused window; otherwise it
  is activated and AX-raised (D8). Each click logs the target id and focus outcome. Keys go to
  an adopted child while it is the front normal window, else W (D25).
  `menu.press` never switches the view; a window it opens appears in the composite.
- **Limits.** Children on another display and a W spanning displays are not composited. The
  composite shows whatever of P's included windows covers W as on screen (other apps' windows
  are left out). D35 fit resizes W only; with children the video aspect is the composite's.
  A child appears up to about 0.5 s after it opens. Windows P opened before viewing W (except
  floating ones) never join.
- **Source changes:** `ChildWindows.swift`, `CaptureSession.swift`, `MacBackend.swift`,
  `WindowFocuser.swift`.

### D44 acceptance criteria
On the real Mac and iPhone:
1. Viewing a Logic Pro project, opening Melodyne shows its window in the video; a tap on it
   reaches Melodyne at that spot.
2. Viewing TextEdit, ☰ → TextEdit → Settings… shows the Settings window in the video next to
   the document; tapping the document keeps Settings shown; closing Settings returns the video
   to the document alone.
3. Another TextEdit document that was already open is not shown.
4. A window with no floating or new windows streams exactly as before.
5. *Unit:* floating selection (layer range, same pid, 60 pt minimum), overlays (in front,
   80 % containment, half-area cap, 8 pt minimum), no raise when P's window is topmost, adoption of new layer-0
   windows, kept until closed, pre-existing excluded, union and display clamping, no children
   ⇒ plain window, change detection, click/key focus targets, click hit test in front-to-back
   order past other apps' and system overlay windows (`ChildWindowsTests`).

## 24. Desktop browser with a mouse and a physical keyboard (user decision, Issue #19)

### D45. Mouse and keyboard on a PC browser; the iPhone is unchanged
- **Why (user request):** operate the Mac window from a desktop browser as directly as sitting
  at the Mac. Touch input (D23, D24) and the iPhone text field (D10, D34) do not change.
- **Mouse (`pointerType === 'mouse'`).** Absolute mapping: the point under the mouse on the
  video is the window point. Moves go at most once per animation frame on `motion` as
  `{"t":"point","seq","u","v"}` (u, v in [0, 1]; `seq` shares the `move` counter and a point
  older than the last applied `seq` is dropped, since `motion` is unordered). Buttons go on
  `control` as `{"t":"mouse","button":"left|right|middle","state":"down|up","clicks":1–3,
  "seq","u","v"}`: the Mac moves the cursor there and posts the button's down or up with
  `clicks` as the click state (a double-click is the browser's `detail` 2, so the Mac sees
  clickCount 2). While a button is held the Mac posts the button's dragged events, and the
  point is clamped to the window edge. One button at a time; a held button is released on
  disconnect or window change as before (D26). The wheel sends the existing `scroll`
  (pixel deltas; line mode ×16 px, page mode × the stage height; both axes; ctrl+wheel, a
  trackpad pinch, is swallowed). The context menu is suppressed. The phone's arrow overlay
  is not drawn for a mouse; the browser's own cursor stays visible because the stream does
  not render the Mac cursor (`showsCursor = false`). No pointer lock.
- **Keyboard.** Active when the viewer is shown on a desktop (a mouse was pressed on the
  stage, or `(pointer: fine)` matches) and no sheet, ⋯ menu, slot menu, or text field is in
  use. Keys arrive in a hidden, focused textarea (`#key-sink`) so an IME can compose. A
  keydown with no modifier but shift (or with AltGr) whose `key` is one printable character is
  sent as `text` (the user's layout is respected); otherwise `KeyboardEvent.code` is mapped by
  US position to a §4.3 key name and sent as `key` with `mods` from metaKey→cmd, ctrlKey→ctrl,
  altKey→opt, shiftKey→shift (D38 Fn/NumPad flags apply on the Mac as for the key panel).
  Forwarded keys, and their keyups, are `preventDefault`ed. Modifier keys alone, unmapped
  keys, dead keys, and anything during IME composition are not forwarded; `compositionend`
  sends the committed text through `text`. Clicking a bottom-bar or panel button returns focus
  to the key sink.
- **Limits.** Keys the browser or OS keeps are never seen by the page (e.g. ⌘Tab, ⌘Q, ⌘W, ⌘T,
  ⌘N and ⌘L in most browsers, Ctrl+Alt+Del, the Windows key); use the key panel's ⌘Tab / ⌘F1 /
  ⌘Q for those. Option+letter goes as ⌥+key (the Mac's own layout decides the character), and
  keys beyond §4.3 (F13+, media keys, Intl keys) are ignored. Keys do not repeat faster than the
  browser's auto-repeat, and each is one combo (down and up) on the Mac, so holding a key on
  the Mac (e.g. a game) is not possible.
- **Source changes:** `Protocol.swift` (`point`, `mouse`), `Session.swift`,
  `InputPipeline.swift` (`submitPoint`, `submitMouse`), `InputInjector.swift` (held button of
  any kind), `MacBackend.swift`; `web/desktop.js`, `web/viewer.js`, `web/app.js`, `web/rtc.js`,
  `web/index.html`, `web/style.css`.

### D45 acceptance criteria
On a desktop browser (Chrome or Safari on a PC or another Mac) against the real Mac:
1. Moving the mouse over the video moves the Mac cursor to the same spot in the window;
   no arrow overlay is drawn.
2. Click, double-click (selects a word in TextEdit), right-click (opens the context menu,
   not the browser's), and drag (selects text or moves a window item) work where the mouse is.
3. The wheel scrolls the window in both directions and axes.
4. Typing letters, digits, and symbols (on the user's layout), Enter, Backspace, Tab, Esc,
   arrows, Home/End/PageUp/PageDown, F1–F12 goes to the window; ⌘C/⌘V/⌘Z and ⌃/⌥ combos work.
5. With a Japanese IME, composing shows candidates in the browser and only the committed text
   arrives on the Mac.
6. The ⋯ menu, ☰ sheet, paste sheet, and the text field receive keys themselves; nothing is
   forwarded while they are in use. The bottom bar and key panel work with the mouse.
7. On the iPhone, the trackpad, overlay arrow, text field, and key panel behave as before.
8. *Unit:* `point`/`mouse` decoding and channels; absolute cursor and stale points in the
   pipeline; web code→key mapping, text-vs-combo decision, IME composition, mouse button,
   click count, wheel, and stage→window translation.

## 25. 🔊 on a desktop browser (Issue #21; amends D39)

### D46. The audio element re-loads its stream on a new track, and a pending play() after a user gesture counts as unlocked

Desktop Chrome left 🔊 on "tap to enable": a track added to the stream that is already the `<audio>` source was not picked up, and `play()` stayed pending, so the click only tried to unlock and never cycled. `setTrack` now re-assigns `srcObject`, and if `play()` has not settled after 0.8 s while the page has sticky user activation (`navigator.userActivation.hasBeenActive`), the element counts as unlocked. iOS is unchanged (its play() settles).

Acceptance: in a desktop browser a click on 🔊 cycles Off → App → All and the Mac's sound plays; the iPhone behaves as before.

## 26. Download files from the Mac (user decision, Issue #23)

### D47. ⬇︎ Download in the ⋯ menu: a file browser, name search, and one-time download links
- **Entry.** ⋯ → ⬇︎ Download (after 📎 File) opens a full-height sheet (touch and mouse). It starts
  at the home folder (then where it was last). Quick places: Home, Desktop, Documents,
  Downloads, Computer (`/`), and each `/Volumes/*` except the boot-disk link. A breadcrumb
  header and ‹ go up. Rows: icon, name, size, date; folders first, then name (localized,
  case-insensitive). A Hidden toggle shows dot-files. An unreadable folder shows "No access".
- **Listing and search over the socket.** `{"t":"files.list","id","path","hidden"}` →
  `{"t":"files","id","path","entries","total","truncated","places"}`; at most 5,000 entries,
  with "Showing the first N of M". `{"t":"files.search","id","base","q","hidden"}` →
  `{"t":"files.found","id","base","entries","truncated","timedOut"}`: a file-NAME
  case-insensitive substring match. "Search in:" defaults to the current folder, is editable
  (`~` expands), and has quick picks "current folder" and "/". The walk skips package contents,
  hidden entries unless shown, and, from `/`, `/System`, `/private`, and `/dev`. It stops at 500
  matches or about 5 s, and a newer search cancels it. Results show their parent path and can
  be selected.
- **Download.** A checkbox per row (a tap on a file row toggles it too) and a sticky bar
  "N selected · size" with Download. `{"t":"download.request","id","paths"}` checks each path on
  the Mac (absolute, standardized, must exist and be readable; `/` itself is refused) and
  pre-scans folders. Over 2 GB (file sizes before compression) or 100,000 files → `too_large`
  with a clear message, before anything is sent. Otherwise → `{"t":"download.ready","id","url",
  "name","size"}` with `url` = `/download/<token>`: 48 hex characters, valid once, for 60 s,
  for exactly that path set. The page navigates a hidden `<a download>` to it, so iOS Safari
  and desktop browsers save the file. The GET goes through the owner check (D32).
- **Response.** One file → as is (`application/octet-stream`, `Content-Length`). Several items or
  any folder → one zip streamed while it is built: relative paths under each selected item's
  name, ZIP64 when sizes or offsets need it, STORE for already-compressed types, DEFLATE
  otherwise. Name: `<folder>.zip`, `<shared parent>.zip`, or `download-<yyyyMMdd-HHmmss>.zip`.
  `Content-Disposition: attachment; filename="<ASCII fallback>"; filename*=UTF-8''<name>`.
- **Read only.** Nothing is created, changed, or deleted on the Mac.
- **Limits.** Folders are zipped with hidden files; symlinked folders inside are not entered;
  unreadable items inside a folder are left out. Privacy-protected folders (TCC) show "No
  access" unless the app has been given access. A file that changes during the download is sent
  as read.

### D47 acceptance criteria
- ⋯ shows ⬇︎ Download after 📎 File; it opens at home with the quick places.
- Folders open on tap; ‹ and the breadcrumbs go up; Hidden shows dot-files.
- Checking one file and Download saves it with its name; checking a folder or several items
  saves one zip that `unzip -t` accepts.
- A selection over 2 GB shows the limit message and downloads nothing.
- Search finds names under the current folder, `/`, or a typed `~/…` path within about 5 s.
- A used or expired `/download/…` link answers 404.

## 27. ⌘W instead of ⌘Tab in the key panel (user decision; amends D37)

### D48. The third row's second key is ⌘W

The user closes windows far more often than switching with ⌘Tab, and some apps' title-bar close buttons ignore a synthetic click (Issue #26). The key panel's third row is now ⌘F1, **⌘W**, space, ⏎, ⋯. ⌘W is an ordinary combo (`w` with `cmd`) sent to the viewed window's app; when that closes the viewed window, the existing window-closed handling applies. ⌘Tab is still available as ⌘ then tab.

Acceptance: ⌘W in the key panel closes the Mac's front window of the viewed app (for example Logic Pro's Settings panel); ⌘ then tab still switches apps.
