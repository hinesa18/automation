import Cocoa
import ApplicationServices
import Carbon
import Vision

enum ScreenText {
    static func recognize(_ imageURL: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(url: imageURL, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.012 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// No third-party packages, network access, or keyboard logging.
struct TriggerMatcher {
    static let trigger = "==autotype=="
    private(set) var buffer = ""

    mutating func reset() { buffer = "" }
    mutating func feed(_ text: String) -> Bool {
        buffer += text
        while !Self.trigger.hasPrefix(buffer) && !buffer.isEmpty {
            buffer.removeFirst()
        }
        if buffer == Self.trigger { reset(); return true }
        return false
    }
}

struct ResumeMatcher {
    private(set) var prefix = ""
    private var atBoundary = true
    mutating func reset() { prefix = ""; atBoundary = true }
    mutating func feed(_ text: String) -> Bool {
        for character in text {
            if !prefix.isEmpty || atBoundary {
                let candidate = prefix + String(character)
                prefix = "resume".hasPrefix(candidate) ? candidate : ""
                if prefix == "resume" { reset(); return true }
            }
            atBoundary = !(character.isLetter || character.isNumber || character == "_")
        }
        return false
    }
}

struct TypingJob {
    let pieces: [String]
    private(set) var position = 0
    let interval: TimeInterval
    let variedTiming: Bool
    let keypressMode: Bool
    let charactersPerPress: Int
    var remaining: String { pieces.dropFirst(position).joined() }
    var next: String? { position < pieces.count ? pieces[position] : nil }
    private(set) var queuedCharacters = 0
    var readyToEmit: Bool { !keypressMode || queuedCharacters > 0 }
    // Single-character mode follows each physical press with no cooldown.
    // Larger batches animate character by character, about 12 chars/sec.
    var keypressInterval: TimeInterval { charactersPerPress == 1 ? 0 : 0.08 }
    var pausedCopy: TypingJob {
        var copy = self
        copy.queuedCharacters = 0
        return copy
    }
    mutating func queueKeypress() {
        guard keypressMode else { return }
        queuedCharacters = min(pieces.count - position, queuedCharacters + charactersPerPress)
    }
    mutating func advance() {
        if position < pieces.count {
            position += 1
            queuedCharacters = max(0, queuedCharacters - 1)
        }
    }

    // Inject random values in tests so timing checks remain deterministic.
    func delay(after piece: String, jitter: Double = .random(in: 0...1),
               hesitation: Double = .random(in: 0...1)) -> TimeInterval {
        guard variedTiming else { return interval }
        var delay = interval * (0.65 + 0.7 * jitter)
        if piece == "\n" { delay += min(1.2, interval * 5) }
        else if [".", "!", "?", "…"].contains(piece) { delay += min(0.8, interval * 3) }
        else if [",", ";", ":", "—"].contains(piece) { delay += min(0.4, interval * 1.5) }
        else if piece == " " { delay += interval * (0.2 + 0.5 * jitter) }
        if hesitation < 0.025 { delay += min(0.8, interval * 4) }
        return delay
    }

    func acceptsKeypress(isRepeat: Bool, hasShortcutModifiers: Bool) -> Bool {
        keypressMode && !isRepeat && !hasShortcutModifiers
    }

    init(text: String, wpm: Double, variedTiming: Bool = false, keypressMode: Bool = false,
         charactersPerPress: Int = 1) throws {
        self.variedTiming = variedTiming
        self.keypressMode = keypressMode
        self.charactersPerPress = min(20, max(1, charactersPerPress))
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { throw InputError.empty }
        // Tabs can move focus to another field; type four spaces instead.
        let safe = normalized.replacingOccurrences(of: "\t", with: "    ")
        guard !safe.unicodeScalars.contains(where: {
            ($0.value < 32 && $0.value != 10) || (127...159).contains($0.value)
        }) else { throw InputError.control }
        var result: [String] = []
        for character in safe {
            var chunk = ""
            for scalar in String(character).unicodeScalars {
                if chunk.utf16.count + scalar.utf16.count > 20 {
                    result.append(chunk); chunk = ""
                }
                chunk.unicodeScalars.append(scalar)
            }
            if !chunk.isEmpty { result.append(chunk) }
        }
        pieces = result
        interval = 60 / (min(500, max(10, wpm)) * 5)
    }

    enum InputError: LocalizedError {
        case empty, control
        var errorDescription: String? {
            switch self {
            case .empty: return "Enter some text, or copy text to the clipboard first."
            case .control: return "This text contains unsupported control characters. Use plain text."
            }
        }
    }
}

final class InputView: NSTextView {
    var start: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift) {
            start?()
        } else { super.keyDown(with: event) }
    }
}

final class AutoType: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    enum Phase { case idle, deleting, configuring, returning, running }
    private var phase: Phase = .idle
    private var matcher = TriggerMatcher()
    private var resumeMatcher = ResumeMatcher()
    private var pausedJob: TypingJob?
    private var resumingAfterDeletion = false
    private var job: TypingJob?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let eventSource = CGEventSource(stateID: .privateState)!
    private let eventTag: Int64 = 0x4155544F54595045
    private var timer: Timer?
    private var target: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var focusedElement: AXUIElement?
    private var suppressedKeys = Set<Int64>()
    private var status: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var window: NSWindow!
    private var editor: InputView!
    private var clipboardBox: NSButton!
    private var variedTimingBox: NSButton!
    private var keypressBox: NSButton!
    private var speed: NSSlider!
    private var keypressAmount: NSSlider!
    private var speedLabel: NSTextField!
    private var hint: NSTextField!
    private var manualDraft = ""
    private var workspaceObserver: NSObjectProtocol?
    private var healthTimer: Timer?
    private var previousTrust: Bool?
    private var previousSecureInput: Bool?
    private var statusWindow: NSWindow?
    private var accessLabel: NSTextField?
    private var currentStatus = "Starting"
    private var keyEventsSeen = 0
    private var lastDiagnostics = Data()
    private var terminationSignal: DispatchSourceSignal?
    private var capturingScreenText = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch must not install a second keyboard interceptor.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.autotype.utility").count > 1 {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        // The launcher can restart safely, preserving pending text before exit.
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()
        eventSource.userData = eventTag
        buildMenu()
        buildWindow()
        if CommandLine.arguments.contains("--preview") {
            phase = .configuring
            clipboardBox.state = .off
            manualDraft = "Try a short paragraph at your preferred speed.\n\nEscape saves the remaining text so you can continue later."
            refreshSource()
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            setStatus("Preview — keyboard monitoring off")
            return
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.resetTriggers()
            if !self.capturingScreenText,
               let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.lastExternalApp = front
            }
            if self.phase == .running || self.phase == .deleting {
                if !self.targetIsFrontmost { self.stop("App changed — remaining text copied") }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = front
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            let secure = IsSecureEventInputEnabled()
            if self.isBlocking && (!trusted || secure) {
                self.stop("Keyboard access changed — remaining text copied")
            }
            if self.previousTrust != trusted {
                self.previousTrust = trusted
                if trusted { self.connectKeyboard(showHelp: false) }
                else {
                    self.disconnectKeyboard()
                    self.setStatus("Waiting for Accessibility permission")
                }
            }
            if trusted, self.previousSecureInput != secure, self.phase == .idle {
                self.setStatus(secure ? "Secure keyboard input is active — waiting" :
                    (self.tap != nil ? "Ready — type ==autotype==" : "Keyboard listener unavailable — choose Check permissions"))
            }
            self.previousSecureInput = secure
            self.writeDiagnostics()
        }
        connect()
    }

    private var isBlocking: Bool {
        phase == .deleting || phase == .returning || phase == .running
    }
    private func resetTriggers() {
        matcher.reset()
        resumeMatcher.reset()
    }

    private var targetIsFrontmost: Bool {
        guard let target, !target.isTerminated else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func buildMenu() {
        // Native text editing shortcuts require a responder-chain Edit menu.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit AutoType", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                     ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "AT"
        let menu = NSMenu()
        menu.delegate = self
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        let startItem = NSMenuItem(title: "Start…", action: #selector(startFromMenu), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        let captureItem = NSMenuItem(title: "Capture text from screen…", action: #selector(captureTextFromScreen), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        let captureAndStartItem = NSMenuItem(title: "Capture and Start…", action: #selector(captureAndStart), keyEquivalent: "")
        captureAndStartItem.target = self
        menu.addItem(captureAndStartItem)
        menu.addItem(NSMenuItem(title: "Type ==autotype== in your document", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        for (title, action) in [("Status and permissions", #selector(showPermissionHelp)),
                                ("Check permissions", #selector(connect)),
                                ("Stop and copy remaining text", #selector(stopFromMenu)),
                                ("Quit AutoType", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        status.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Capture focus before the menu or setup window can take it away.
        guard !capturingScreenText else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            captureTarget(front)
        }
    }

    private func captureTarget(_ application: NSRunningApplication) {
        target = application
        lastExternalApp = application
        focusedElement = nil
        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            focusedElement = (value as! AXUIElement)
        }
    }

    @objc private func startFromMenu() {
        guard phase == .idle else { return }
        guard !capturingScreenText else { setStatus("Finish selecting the screen area first"); return }
        guard tap != nil, AXIsProcessTrusted() else { showPermissionHelp(); return }
        guard let application = lastExternalApp, !application.isTerminated else {
            setStatus("Open a document, then choose Start…")
            return
        }
        if target?.processIdentifier != application.processIdentifier { captureTarget(application) }
        showComposer()
    }

    @objc private func captureTextFromScreen() {
        beginScreenCapture(autoStart: false)
    }

    @objc private func captureAndStart() {
        beginScreenCapture(autoStart: true)
    }

    private func capturedJob(text: String, fromComposer: Bool) throws -> TypingJob {
        if fromComposer {
            return try TypingJob(text: text, wpm: speed.doubleValue,
                                 variedTiming: variedTimingBox.state == .on,
                                 keypressMode: keypressBox.state == .on,
                                 charactersPerPress: Int(keypressAmount.doubleValue))
        }
        let preferences = UserDefaults.standard
        let savedWPM = preferences.double(forKey: "wpm")
        return try TypingJob(text: text, wpm: savedWPM == 0 ? 80 : savedWPM,
                             variedTiming: preferences.bool(forKey: "variedTiming"),
                             keypressMode: preferences.bool(forKey: "keypressMode"),
                             charactersPerPress: preferences.integer(forKey: "charactersPerPress"))
    }

    private func saveComposerSettings() {
        let preferences = UserDefaults.standard
        preferences.set(speed.doubleValue, forKey: "wpm")
        preferences.set(variedTimingBox.state == .on, forKey: "variedTiming")
        preferences.set(keypressBox.state == .on, forKey: "keypressMode")
        preferences.set(Int(keypressAmount.doubleValue), forKey: "charactersPerPress")
    }

    private func restoreComposerAfterCapture(_ message: String, fromComposer: Bool) {
        setStatus(message)
        guard fromComposer else { return }
        hint.stringValue = message
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func beginScreenCapture(autoStart: Bool) {
        let fromComposer = phase == .configuring
        guard !capturingScreenText,
              phase == .idle || (autoStart && fromComposer) else { return }
        if autoStart {
            guard tap != nil, AXIsProcessTrusted() else { showPermissionHelp(); return }
            guard let destination = target ?? lastExternalApp, !destination.isTerminated else {
                setStatus("Open a document before Capture and Start")
                return
            }
            if target == nil { captureTarget(destination) }
        }
        capturingScreenText = true
        if fromComposer { window.orderOut(nil) }
        setStatus("Drag to select text on screen — Escape cancels")
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoType-Capture-\(UUID().uuidString).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-i", "-s", "-x", "-t", "png", imageURL.path]
        capture.terminationHandler = { [weak self] process in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<String, Error>
                if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: imageURL.path) {
                    result = Result { try ScreenText.recognize(imageURL) }
                } else {
                    result = .failure(CaptureError.cancelled)
                }
                try? FileManager.default.removeItem(at: imageURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.capturingScreenText = false
                    switch result {
                    case .success(let recognized) where !recognized.isEmpty:
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(recognized, forType: .string) {
                            if autoStart {
                                do {
                                    let pending = try self.capturedJob(text: recognized, fromComposer: fromComposer)
                                    if fromComposer { self.saveComposerSettings() }
                                    self.beginTyping(pending)
                                } catch {
                                    self.restoreComposerAfterCapture("Could not start with captured text", fromComposer: fromComposer)
                                }
                            } else { self.setStatus("Text copied — choose Start…") }
                        } else {
                            self.restoreComposerAfterCapture("Could not copy recognized text", fromComposer: fromComposer)
                        }
                    case .success:
                        self.restoreComposerAfterCapture("No readable text found — clipboard unchanged", fromComposer: fromComposer)
                    case .failure(CaptureError.cancelled):
                        self.restoreComposerAfterCapture("Capture canceled — clipboard unchanged", fromComposer: fromComposer)
                    case .failure:
                        self.restoreComposerAfterCapture("Could not read captured text — clipboard unchanged", fromComposer: fromComposer)
                    }
                }
            }
        }
        do { try capture.run() }
        catch {
            capturingScreenText = false
            restoreComposerAfterCapture("Could not start screen capture", fromComposer: fromComposer)
        }
    }

    private enum CaptureError: Error { case cancelled }

    @objc private func connect() {
        connectKeyboard(showHelp: true)
    }

    private func connectKeyboard(showHelp: Bool) {
        guard !isBlocking else { return }
        let trusted = AXIsProcessTrusted()
        previousTrust = trusted
        guard trusted else {
            disconnectKeyboard()
            setStatus("Waiting for Accessibility permission")
            if showHelp {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                showPermissionHelp()
            }
            return
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) {
                setStatus("Ready — type ==autotype==")
                return
            }
            disconnectKeyboard()
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown,
                                    .rightMouseDown, .otherMouseDown, .scrollWheel,
                                    CGEventType(rawValue: 14)!]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: mask,
                               callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<AutoType>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            setStatus("Keyboard listener unavailable — check Input Monitoring")
            if showHelp {
                _ = CGRequestListenEventAccess()
                showPermissionHelp()
            }
            return
        }
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setStatus("Ready — type ==autotype==")
    }

    private func disconnectKeyboard() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
        resetTriggers(); suppressedKeys.removeAll()
    }

    @objc private func showPermissionHelp() {
        if statusWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 280),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "AutoType Status"
            panel.isReleasedWhenClosed = false
            let label = NSTextField(wrappingLabelWithString: "")
            label.frame = NSRect(x: 24, y: 74, width: 552, height: 180)
            label.font = .systemFont(ofSize: 14)
            panel.contentView?.addSubview(label)
            accessLabel = label
            let settings = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibility))
            settings.frame = NSRect(x: 24, y: 22, width: 270, height: 32)
            panel.contentView?.addSubview(settings)
            let check = NSButton(title: "Check again", target: self, action: #selector(connect))
            check.frame = NSRect(x: 400, y: 22, width: 176, height: 32)
            panel.contentView?.addSubview(check)
            statusWindow = panel
        }
        updateAccessLabel()
        statusWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        statusWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func updateAccessLabel() {
        accessLabel?.stringValue = "\(currentStatus)\n\nEnable AutoType in Privacy & Security → Accessibility. If it already appears enabled but access is rejected, remove the old AutoType entry with the minus button, then add ~/Applications/AutoType.app again and enable it.\n\nAutoType reconnects when permission is granted. This window updates automatically."
    }

    private func writeDiagnostics() {
        // Status only: never record typed characters, document text, or clipboard data.
        let values: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "status": currentStatus, "accessibilityTrusted": AXIsProcessTrusted(),
            "inputMonitoringAllowed": CGPreflightListenEventAccess(),
            "eventTapEnabled": tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            "secureInput": IsSecureEventInputEnabled(), "phase": String(describing: phase),
            "keyEventsSeen": keyEventsSeen]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]),
              data != lastDiagnostics else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoType", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
            lastDiagnostics = data
        } catch { /* A diagnostics write failure must never interrupt typing. */ }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop("Keyboard monitor interrupted — remaining text copied")
            suppressedKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == eventTag {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { keyEventsSeen += 1 }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, suppressedKeys.remove(code) != nil { return nil }
        // Keep swallowing repeats of the final key until it is released, even
        // after that key has completed a manually paced run.
        if type == .keyDown, suppressedKeys.contains(code),
           event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        // Scrolling moves the viewport, not the insertion point. Always pass it
        // through without ending a run or discarding a partially typed trigger.
        if type == .scrollWheel { return Unmanaged.passUnretained(event) }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            resetTriggers()
            if isBlocking { stop("Pointer moved focus — remaining text copied") }
            return Unmanaged.passUnretained(event)
        }
        if isBlocking {
            if type == .keyDown {
                suppressedKeys.insert(code)
                if code == 53 { stop("Stopped — remaining text copied") }
                else if phase == .running, job?.acceptsKeypress(
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    hasShortcutModifiers: !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
                ) == true {
                    job?.queueKeypress()
                    // One timer drains the queue. Rapid presses add work without
                    // bypassing the delay or creating overlapping typing loops.
                    if timer?.isValid != true { typeNext() }
                }
            }
            return nil
        }
        guard phase == .idle, type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty == false
            || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            resetTriggers(); return Unmanaged.passUnretained(event)
        }
        var count = 0
        var chars = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &count, unicodeString: &chars)
        let text = String(utf16CodeUnits: chars, count: count)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            resetTriggers(); return Unmanaged.passUnretained(event)
        }
        let opensComposer = matcher.feed(text)
        let canResume = pausedJob != nil
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && !IsSecureEventInputEnabled()
        let resumes = canResume && resumeMatcher.feed(text)
        if opensComposer || resumes {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !IsSecureEventInputEnabled() else { return Unmanaged.passUnretained(event) }
            captureTarget(front)
            phase = .deleting
            resumingAfterDeletion = resumes && !opensComposer
            resetTriggers()
            if resumingAfterDeletion {
                // Deliver the complete word normally, including its final e.
                // Only after the editor has processed it do we erase six letters.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.phase == .deleting, self.resumingAfterDeletion else { return }
                    self.eraseTrigger(remaining: "resume".count)
                }
                return Unmanaged.passUnretained(event)
            }
            suppressedKeys.insert(code)
            // The final ==autotype== character is swallowed, unlike resume.
            eraseTrigger(remaining: TriggerMatcher.trigger.count - text.count)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func eraseTrigger(remaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.phase == .deleting else { return }
            guard self.targetIsFrontmost else { self.stop("Stopped — target changed"); return }
            if remaining > 0 {
                guard self.post(key: 51) else { self.stop("Could not send keyboard events"); return }
                self.eraseTrigger(remaining: remaining - 1)
            } else if self.resumingAfterDeletion, let pending = self.pausedJob {
                self.beginTyping(pending)
            } else { self.showComposer() }
        }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 554),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AutoType"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = window.contentView!
        func label(_ text: String, _ frame: NSRect) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text)
            view.frame = frame; content.addSubview(view); return view
        }
        let title = label("Type at your pace", NSRect(x: 24, y: 500, width: 530, height: 30))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        speedLabel = label("", NSRect(x: 24, y: 462, width: 530, height: 24))
        let saved = UserDefaults.standard.double(forKey: "wpm")
        speed = NSSlider(value: saved == 0 ? 80 : saved, minValue: 10, maxValue: 500,
                         target: self, action: #selector(speedChanged))
        speed.frame = NSRect(x: 24, y: 427, width: 530, height: 26)
        content.addSubview(speed); speedChanged()
        let savedAmount = UserDefaults.standard.integer(forKey: "charactersPerPress")
        keypressAmount = NSSlider(value: Double(min(20, max(1, savedAmount))), minValue: 1, maxValue: 20,
                                  target: self, action: #selector(keypressAmountChanged))
        keypressAmount.frame = speed.frame
        keypressAmount.numberOfTickMarks = 20
        keypressAmount.allowsTickMarkValuesOnly = true
        keypressAmount.setAccessibilityLabel("Characters per keypress")
        content.addSubview(keypressAmount)
        variedTimingBox = NSButton(checkboxWithTitle: "Vary typing speed and pause naturally", target: self,
                                   action: #selector(modeChanged))
        variedTimingBox.frame = NSRect(x: 24, y: 388, width: 530, height: 26)
        variedTimingBox.state = UserDefaults.standard.bool(forKey: "variedTiming") ? .on : .off
        content.addSubview(variedTimingBox)
        keypressBox = NSButton(checkboxWithTitle: "Type with my keypresses — I control the pace", target: self,
                              action: #selector(modeChanged))
        keypressBox.frame = NSRect(x: 24, y: 352, width: 530, height: 26)
        keypressBox.state = UserDefaults.standard.bool(forKey: "keypressMode") ? .on : .off
        content.addSubview(keypressBox)
        clipboardBox = NSButton(checkboxWithTitle: "Use text copied to my clipboard", target: self,
                                action: #selector(sourceChanged))
        clipboardBox.frame = NSRect(x: 24, y: 312, width: 530, height: 26)
        clipboardBox.state = .on; content.addSubview(clipboardBox)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 112, width: 532, height: 186))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        editor = InputView(frame: NSRect(x: 0, y: 0, width: 530, height: 186))
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.start = { [weak self] in self?.startTyping() }
        scroll.documentView = editor; content.addSubview(scroll)
        hint = label("", NSRect(x: 24, y: 62, width: 532, height: 42))
        hint.font = .systemFont(ofSize: 12)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelComposer))
        cancel.frame = NSRect(x: 342, y: 18, width: 100, height: 32)
        cancel.keyEquivalent = "\u{1b}"; content.addSubview(cancel)
        let start = NSButton(title: "Start", target: self, action: #selector(startTyping))
        start.bezelStyle = .rounded
        start.frame = NSRect(x: 452, y: 18, width: 104, height: 32)
        start.keyEquivalent = "\r"; content.addSubview(start)
        let captureAndStart = NSButton(title: "Capture and Start…", target: self, action: #selector(captureAndStart))
        captureAndStart.frame = NSRect(x: 24, y: 18, width: 212, height: 32)
        content.addSubview(captureAndStart)
        modeChanged()
    }

    private func showComposer() {
        phase = .configuring
        // Every new run offers the clipboard, including a stopped run's remainder.
        clipboardBox.state = .on
        refreshSource()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func speedChanged() {
        speed.doubleValue = speed.doubleValue.rounded()
        speedLabel.stringValue = "\(Int(speed.doubleValue)) words per minute"
    }

    @objc private func modeChanged() {
        let manual = keypressBox.state == .on
        speed.isHidden = manual
        keypressAmount.isHidden = !manual
        variedTimingBox.isEnabled = !manual
        if manual { keypressAmountChanged() }
        else { speedChanged() }
        updateHint()
    }

    @objc private func keypressAmountChanged() {
        keypressAmount.doubleValue = keypressAmount.doubleValue.rounded()
        let amount = Int(keypressAmount.doubleValue)
        speedLabel.stringValue = "1 keypress = \(amount) \(amount == 1 ? "character" : "characters")"
    }

    private func updateHint() {
        hint.stringValue = keypressBox.state == .on
            ? "Each key queues characters to type one at a time. Scrolling is allowed.\nEscape stops and copies what’s left, including queued characters."
            : "Enter starts • Shift+Enter adds a line • Escape stops and copies what’s left.\nKeep the destination focused. Tabs become four spaces."
    }

    @objc private func sourceChanged() {
        if clipboardBox.state == .on { manualDraft = editor.string }
        refreshSource()
    }

    private func refreshSource() {
        let clipboard = clipboardBox.state == .on
        editor.isEditable = !clipboard
        editor.string = clipboard ? (NSPasteboard.general.string(forType: .string) ?? "") : manualDraft
        updateHint()
        if !clipboard { window.makeFirstResponder(editor) }
    }

    @objc private func startTyping() {
        guard phase == .configuring else { return }
        let pending: TypingJob
        do { pending = try TypingJob(text: editor.string, wpm: speed.doubleValue,
                                    variedTiming: variedTimingBox.state == .on,
                                    keypressMode: keypressBox.state == .on,
                                    charactersPerPress: Int(keypressAmount.doubleValue)) }
        catch { hint.stringValue = error.localizedDescription; NSSound.beep(); return }
        guard !CommandLine.arguments.contains("--preview") else {
            hint.stringValue = "Preview only. Close this preview and open AutoType normally to type."
            return
        }
        if clipboardBox.state == .off { manualDraft = editor.string }
        saveComposerSettings()
        beginTyping(pending)
    }

    private func beginTyping(_ pending: TypingJob) {
        job = pending
        pausedJob = nil
        resumingAfterDeletion = false
        phase = .returning
        window.orderOut(nil)
        setStatus("Returning to document — Escape cancels")
        guard let target, !target.isTerminated else { stop("Target closed — text copied"); return }
        target.activate(options: [])
        if let focusedElement {
            AXUIElementSetMessagingTimeout(focusedElement, 0.1)
            _ = AXUIElementSetAttributeValue(focusedElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        // Give the original app time to regain focus, and wait for held keys to lift.
        let deadline = Date().addingTimeInterval(5)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.phase == .returning else { return }
            if Date() > deadline { self.stop("Could not restore focus — text copied"); return }
            guard deadline.timeIntervalSinceNow < 4.3, self.targetIsFrontmost else { return }
            let flags = CGEventSource.flagsState(.hidSystemState)
            guard flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty else { return }
            guard !(0..<128).contains(where: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }) else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.phase = .running
            if self.job?.keypressMode == true {
                self.setStatus("Press keys to type — Escape stops")
            } else {
                self.setStatus("Typing — Escape stops")
                self.typeNext()
            }
        }
    }

    private func typeNext() {
        guard phase == .running else { return }
        guard targetIsFrontmost, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            stop("Destination or keyboard access changed — remaining text copied"); return
        }
        guard let piece = job?.next else {
            job = nil; pausedJob = nil; phase = .idle; resetTriggers()
            setStatus("Finished — type ==autotype== to run again"); return
        }
        guard job?.readyToEmit == true else { return }
        guard post(key: piece == "\n" ? 36 : 0, text: piece == "\n" ? nil : piece) else {
            stop("Could not send keyboard events — remaining text copied"); return
        }
        job?.advance()
        if job?.next == nil {
            job = nil; pausedJob = nil; phase = .idle; resetTriggers()
            setStatus("Finished — type ==autotype== to run again")
            return
        }
        let delay = job!.keypressMode ? job!.keypressInterval : job!.delay(after: piece)
        // A one-character keypress has already emitted its entire queue. Do not
        // install a timer that would delay the user's next physical keypress.
        if job!.keypressMode && delay == 0 { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.typeNext()
        }
    }

    @discardableResult private func post(key: CGKeyCode, text: String? = nil) -> Bool {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            if let text {
                let utf16 = Array(text.utf16)
                utf16.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
            }
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    private func stop(_ message: String) {
        let wasActive = isBlocking
        timer?.invalidate(); timer = nil
        if let job {
            pausedJob = job.next == nil ? nil : job.pausedCopy
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.remaining, forType: .string)
        }
        job = nil; resetTriggers()
        resumingAfterDeletion = false
        if phase != .configuring { phase = .idle }
        if wasActive { setStatus(message) }
    }

    private func setStatus(_ message: String) {
        currentStatus = message
        statusLine.title = message
        status.button?.title = phase == .running ? "AT ●" :
            (message.hasPrefix("Text copied") ? "AT ✓" : "AT")
        status.button?.toolTip = message
        updateAccessLabel()
        writeDiagnostics()
    }

    @objc private func stopFromMenu() { stop("Stopped — remaining text copied") }
    @objc private func cancelComposer() {
        window.orderOut(nil)
        if clipboardBox.state == .off { manualDraft = editor.string }
        phase = .idle; resetTriggers()
        setStatus("Ready — type ==autotype==")
        target?.activate(options: [])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelComposer(); return false }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        stop("Stopped")
        healthTimer?.invalidate()
        disconnectKeyboard()
        currentStatus = "Stopped"
        writeDiagnostics()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}

func selfTest() throws {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        print("PASS: \(name)")
    }
    var matcher = TriggerMatcher()
    let matches = "ordinary typing===autotype==".filter { matcher.feed(String($0)) }.count
    check(matches == 1, "trigger recognizes overlap without retaining ordinary input")
    _ = matcher.feed("==auto"); matcher.reset()
    check(!matcher.feed("type=="), "focus/navigation reset prevents stale triggers")
    var resumeMatcher = ResumeMatcher()
    check(!resumeMatcher.feed("presume"), "resume does not match inside a preceding word")
    check(resumeMatcher.feed(" resume"), "resume matches after a word boundary")
    _ = resumeMatcher.feed("res"); resumeMatcher.reset()
    check(!resumeMatcher.feed("ume"), "navigation cancels a partial resume command")
    resumeMatcher.reset()
    for character in "resum" {
        check(!resumeMatcher.feed(String(character)) && !resumeMatcher.prefix.isEmpty,
              "resume matches only after the complete word")
    }
    check(resumeMatcher.feed("e") && resumeMatcher.prefix.isEmpty,
          "completed resume word is recognized and matcher resets")
    resumeMatcher.reset()
    _ = resumeMatcher.feed("res")
    check(!resumeMatcher.feed("u") && !resumeMatcher.prefix.isEmpty, "partial resume prefix remains recognized")
    check(!resumeMatcher.feed("l") && resumeMatcher.prefix.isEmpty, "ordinary-word mismatch cancels recognition")
    var job = try TypingJob(text: "A👩🏽‍💻e\u{301}\r\nB\tC", wpm: 120)
    check(job.remaining == "A👩🏽‍💻e\u{301}\nB    C", "Unicode, newlines, and tabs normalize correctly")
    job.advance(); job.advance()
    check(job.remaining == "e\u{301}\nB    C", "Escape remainder preserves complete Unicode characters")
    let resumed = try TypingJob(text: job.remaining, wpm: 120)
    check(resumed.remaining == job.remaining, "clipboard remainder resumes without restarting")
    while job.next != nil { job.advance() }
    check(job.remaining.isEmpty, "completed text has no remainder")
    check(abs(job.interval - 0.1) < 0.00001, "WPM uses five characters per word")
    check(job.delay(after: ".", jitter: 0, hesitation: 0) == job.interval,
          "fixed-speed mode keeps its original timing")
    let varied = try TypingJob(text: "Hi, there.\n", wpm: 120, variedTiming: true)
    let quick = varied.delay(after: "a", jitter: 0, hesitation: 1)
    let slow = varied.delay(after: "a", jitter: 1, hesitation: 1)
    check(quick > 0 && quick < varied.interval && slow > varied.interval,
          "varied timing moves above and below the baseline")
    check(varied.delay(after: ".", jitter: 0, hesitation: 1) > quick
          && varied.delay(after: "\n", jitter: 0, hesitation: 1) > varied.delay(after: ".", jitter: 0, hesitation: 1),
          "punctuation and paragraph breaks add longer pauses")
    var manual = try TypingJob(text: "A👩🏽‍💻B", wpm: 120, variedTiming: true, keypressMode: true)
    for (repeated, shortcut) in [(false, false), (true, false), (false, true), (false, false)] {
        if manual.acceptsKeypress(isRepeat: repeated, hasShortcutModifiers: shortcut) { manual.advance() }
    }
    check(manual.remaining == "B", "keypress mode advances once per press and ignores repeats and shortcuts")
    var grouped = try TypingJob(text: "A👩🏽‍💻B\nC", wpm: 120, keypressMode: true, charactersPerPress: 3)
    check(!grouped.readyToEmit, "manual mode waits for a keypress")
    grouped.queueKeypress()
    check(grouped.queuedCharacters == 3 && grouped.remaining == "A👩🏽‍💻B\nC",
          "keypress queues three characters without consuming unsent text")
    grouped.advance()
    check(grouped.queuedCharacters == 2 && grouped.remaining == "👩🏽‍💻B\nC",
          "one emission advances one character and Escape retains the queued remainder")
    let paused = grouped.pausedCopy
    check(paused.remaining == grouped.remaining && paused.queuedCharacters == 0
          && paused.charactersPerPress == 3 && paused.keypressMode && paused.interval == grouped.interval,
          "quiet resume preserves remaining text and settings without replaying old queued keypresses")
    grouped.queueKeypress()
    check(grouped.queuedCharacters == 4, "rapid keypresses queue in order and clamp to remaining text")
    var emitted = "A"
    while grouped.readyToEmit, let piece = grouped.next { emitted += piece; grouped.advance() }
    check(emitted == "A👩🏽‍💻B\nC" && grouped.remaining.isEmpty,
          "queued typing preserves emoji and the partial final batch")
    check(grouped.keypressInterval >= 0.06, "keypress characters have a visible delay")
    let immediate = try TypingJob(text: "ABC", wpm: 80, keypressMode: true, charactersPerPress: 1)
    check(immediate.keypressInterval == 0, "one-character mode has no artificial inter-key delay")
    check(!job.acceptsKeypress(isRepeat: false, hasShortcutModifiers: false),
          "automatic mode ignores physical keys")
    let longCharacter = "a" + String(repeating: "\u{301}", count: 40)
    let longJob = try TypingJob(text: longCharacter, wpm: 80)
    check(longJob.pieces.allSatisfy { $0.utf16.count <= 20 } && longJob.remaining == longCharacter,
          "long combining sequences preserve text within event limits")
    for input in ["", "bad\u{1b}text", "bad\u{7f}text"] {
        do { _ = try TypingJob(text: input, wpm: 80); check(false, "invalid input rejected") }
        catch { print("PASS: invalid input rejected") }
    }
}

if CommandLine.arguments.contains("--self-test") {
    try selfTest()
} else if let index = CommandLine.arguments.firstIndex(of: "--ocr-test"),
          CommandLine.arguments.indices.contains(index + 1) {
    print(try ScreenText.recognize(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
} else {
    let app = NSApplication.shared
    let delegate = AutoType()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
