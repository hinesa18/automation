# AutoType for macOS

## Download and install

For a Mac without developer tools, download the DMG from the
[AutoType release](https://github.com/hinesa18/automation/releases/tag/autotype-v1.0.0).
Open it, drag AutoType to Applications, and follow **Install AutoType.txt** inside.
Requires macOS 13 or later; the app includes both Apple silicon and Intel builds.
This initial friend-testing release is ad-hoc signed and not notarized, so macOS
requires **Privacy & Security → Open Anyway** on first launch. Accessibility
permission is also required. See [Apple's instructions](https://support.apple.com/en-us/102445).

To rebuild the downloadable DMG and exact-source archive, run
`./"Build Release.command"`. Outputs and SHA-256 checksums are in `dist/`.
The release builder does not replace your locally installed app. It defaults to
ad-hoc signing; a future notarized release needs a Developer ID Application
certificate and notarization credentials. The developer launcher below is for
building locally, and is unnecessary for your friend.

A local Swift utility with no Python packages, paid services, or network access. The launcher uses Python 3 (provided with Apple's Command Line Tools) to restart the app safely.

## Start

1. Double-click **Start AutoType.command**. It builds if needed, then restarts AutoType. Builds use Apple's Command Line Tools and an existing Apple Development signing certificate; the verified app lives at `~/Applications/AutoType.app`. The certificate choice is pinned locally so future rebuilds retain the same permission identity. No certificates are purchased or created. If tools are missing, install them with `xcode-select --install`. If there are multiple development certificates, set `AUTOTYPE_SIGNING_IDENTITY` to the desired certificate fingerprint on the first build.
2. Enable **AutoType** under **System Settings → Privacy & Security → Accessibility**. If upgrading from the original ad-hoc-signed version, remove the old AutoType row with the minus button, add `~/Applications/AutoType.app` again, and enable it. Merely toggling the stale row may not update its identity. AutoType checks for newly granted access and reconnects automatically. If macOS also requests **Input Monitoring**, enable it. The **AT → Status and permissions** window reports the current state without blocking the app.
3. Place the cursor in an editable document and type `==autotype==` normally. AutoType removes the trigger and opens its window. You can also click **AT → Start…** in the menu bar to open the same setup window without typing the trigger. Keep the intended document focused before opening the AT menu.
   - To copy text from part of your screen, click **AT → Capture text from screen…**, then drag over the text. When the AT icon shows a check mark, the recognized text is on your clipboard. Click **AT → Start…** and leave the clipboard checkbox selected. Escape cancels a screenshot selection. If nothing is recognized, your existing clipboard is kept.
   - To skip the setup step, click **AT → Capture and Start…** while your destination document is focused, then drag over the source text. AutoType copies the recognized text and immediately starts with your last used WPM, typing mode, variation, and characters-per-keypress settings. You can also use **Capture and Start…** inside the setup window; there it uses the settings currently shown. If you cancel or OCR finds no text, AutoType does not start, and an open setup window returns.
4. Choose **10–500 WPM** with the slider. Leave **Use text copied to my clipboard** checked to use the displayed clipboard snapshot, or uncheck it and enter text. The text box scrolls.
   - **Vary typing speed and pause naturally** adds small speed changes, occasional hesitations, and longer pauses at punctuation and line breaks. WPM is the baseline; pauses make the overall average slower. It changes timing only, without adding typos.
   - **Type with my keypresses — I control the pace** waits for you to press keys after Start. The top slider changes to **characters per keypress (1–20)**. At **1**, each press sends its character immediately, with no artificial delay before the next press. Set it to 3 to queue the next three characters with each press, regardless of which key you press. For batches of 2–20, characters appear one at a time, about 80 ms apart. Rapid presses add to the same queue without inserting a whole batch instantly. Spaces and line breaks count as characters. The final press queues only the remaining characters. Escape cancels the queue and copies everything not yet typed. Holding a key does not repeat, and modifier keys or Command/Control/Option shortcuts do not advance. WPM and varied timing do not apply in this mode; your WPM setting is retained for automatic mode.
5. Click **Start** or press **Enter**. **Shift+Enter** inserts a line break in the manual text box. AutoType returns to your document and starts after a short focus delay.
6. Physical keyboard events are suppressed during automatic typing; in keypress mode they advance the chosen text. **Escape** stops immediately and copies the untyped remainder in either mode. Type the trigger again and leave the clipboard box checked to continue.
7. For a quiet restart, type **`resume`** at the insertion point after stopping. The letters appear immediately as you type. After the complete word reaches the editor, AutoType removes its six letters and continues the saved remainder with the previous WPM, varied timing, typing mode, and characters-per-keypress settings, without opening the setup window. There is no delay on a lone `r` or a partial command. In keypress mode it waits for your next keypress. This uses the saved remainder even if the clipboard has changed. It is available only while AutoType stays open and has unfinished text; a fully completed run has nothing to resume. Starting a new run replaces the saved run. The command matches at the start of a new typing sequence or after a word boundary, not inside words such as `presume`.

The AT menu provides status and Quit. Keep the utility running for the trigger to work; no login item is installed. You can open `~/Applications/AutoType.app` directly after the first build.

## Behavior and limits

- WPM uses the standard five characters per word, including spaces. Timing is approximate and depends on the receiving app.
- Screen capture uses macOS's selection tool and Apple's on-device Vision text recognition. The temporary image is removed immediately after recognition, and only recognized plain text is copied. macOS may request screen capture permission. OCR can misread small, stylized, or low-contrast text and may not preserve complex column layouts; review the text in AutoType before pressing Start.
- Unicode text is supported. Line breaks send Return; tabs become four spaces so they do not move focus. Use multiline editors such as Google Docs or TextEdit: Return can submit a single-line form or chat.
- Scrolling and moving the mouse do not stop either typing mode. Clicking, switching applications, or losing keyboard access stops the run and copies the remainder. The app restores the original application and, where supported, its focused editor. Keep the intended document/tab open and focused.
- Escape during the return-to-document delay copies the entire pending text. Canceling the setup window sends no text. A completed run leaves the clipboard unchanged; an interrupted run replaces its contents with the remaining plain text.
- The resume position tracks characters sent to macOS. It cannot verify that another app accepted them; a slow editor or app-specific input handling can drop or modify characters. Try a short sample in your actual editor first.
- macOS secure input (including password fields), protected system screens, and OS-reserved shortcuts cannot be controlled reliably by a normal app. This is a typing utility, not a system-wide keyboard lock. Input methods, text substitutions, and editor shortcuts may affect the trigger or output.
- Type the trigger continuously at the insertion point. Navigation, clicks, or shortcuts reset detection. Pasting the trigger does not activate it. If you cancel during trigger removal, part of the trigger may remain.
- Only the short trigger prefix is held while idle. Ordinary keystrokes are not logged. Clipboard text is read when the window opens or its checkbox is selected; manual drafts are held in memory. WPM and the two typing-mode preferences are saved when you start. `~/Library/Application Support/AutoType/status.json` contains only process/permission/listener state and an aggregate key-event count; it never contains characters, document text, or clipboard contents.
- Updates use the pinned Apple Development identity instead of a changing ad-hoc code hash. If the certificate is unavailable or expired, the build fails without replacing the installed app or silently switching identities. Migrating to another signing identity requires granting permission again. Keep the app at a stable path.

## Development checks

```sh
./"Start AutoType.command" --self-test
./"Start AutoType.command" --build-only
```

Self-tests exercise trigger overlap/reset, Unicode-safe remainder handling, resume behavior, timing, and invalid input. They do not require permissions or inject keyboard events.

The original build was checked for compilation, local code signature, popup layout, manual paste, Select All, Shift+Enter, and Enter rejecting empty input. The user confirmed the global trigger works after restarting with Accessibility enabled. Self-checks also cover varied timing, punctuation pauses, and keypress-mode advancement. Physical keyboard suppression, Escape handling through the event tap, and typing into Google Docs still need live acceptance checks. For a permission-free UI preview, run `~/Applications/AutoType.app/Contents/MacOS/AutoType --preview`; preview mode cannot type into other apps or replace the clipboard.

Manual acceptance check after granting permissions: in a disposable TextEdit document, type the trigger after a known prefix; confirm only the trigger disappears. Try manual text including emoji and line breaks, press ordinary keys during the run, then Escape midway. Paste the clipboard into a separate scratch document to inspect the remainder. Resume through the trigger and check for missing/duplicated text. Repeat in Google Docs, and check mouse/app-switch cancellation, empty clipboard, and Shift+Enter.

Implementation references: Apple's [event tap API](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) and [Unicode keyboard events](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)).
