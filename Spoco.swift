// Spoco for macOS - global hotkeys for Spotify (play/pause, next, previous).
// Hotkeys come from Carbon's RegisterEventHotKey (no Accessibility permission needed)
// and are sent to Spotify as Apple Events, so they reach Spotify even when a browser
// or another app owns the system's Now Playing controls.
import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Actions and hotkey text

enum Action: Int, CaseIterable {
    case playPause, next, previous

    var key: String { ["PlayPause", "Next", "Previous"][rawValue] }
    var label: String { ["Play/Pause", "Next", "Previous"][rawValue] }
    var defaultHotkey: String { ["Ctrl+Shift+C", "Ctrl+Shift+B", "Ctrl+Shift+Z"][rawValue] } // Winamp's classic hotkeys
    var spotifyEvent: String { ["PlPs", "Next", "Prev"][rawValue] } // from Spotify's scripting dictionary
}

struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier bits: controlKey, optionKey, shiftKey, cmdKey
}

// Name used in Spoco.ini, symbol shown in the UI, and the physical (ANSI) key code.
struct KeyName { let name: String; let symbol: String; let code: Int }

let keyNames: [KeyName] = {
    var keys: [KeyName] = []
    let letters: [(String, Int)] = [
        ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E),
        ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J),
        ("K", kVK_ANSI_K), ("L", kVK_ANSI_L), ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O),
        ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
        ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X), ("Y", kVK_ANSI_Y),
        ("Z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
        ("9", kVK_ANSI_9),
    ]
    for (n, c) in letters { keys.append(KeyName(name: n, symbol: n, code: c)) }
    let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    for (i, c) in fkeys.enumerated() { keys.append(KeyName(name: "F\(i + 1)", symbol: "F\(i + 1)", code: c)) }
    keys += [
        KeyName(name: "Space", symbol: "Space", code: kVK_Space),
        KeyName(name: "Return", symbol: "↩", code: kVK_Return),
        KeyName(name: "Tab", symbol: "⇥", code: kVK_Tab),
        KeyName(name: "Escape", symbol: "⎋", code: kVK_Escape),
        KeyName(name: "Delete", symbol: "⌫", code: kVK_Delete),
        KeyName(name: "ForwardDelete", symbol: "⌦", code: kVK_ForwardDelete),
        KeyName(name: "Home", symbol: "↖", code: kVK_Home),
        KeyName(name: "End", symbol: "↘", code: kVK_End),
        KeyName(name: "PageUp", symbol: "⇞", code: kVK_PageUp),
        KeyName(name: "PageDown", symbol: "⇟", code: kVK_PageDown),
        KeyName(name: "Left", symbol: "←", code: kVK_LeftArrow),
        KeyName(name: "Right", symbol: "→", code: kVK_RightArrow),
        KeyName(name: "Up", symbol: "↑", code: kVK_UpArrow),
        KeyName(name: "Down", symbol: "↓", code: kVK_DownArrow),
        KeyName(name: "Minus", symbol: "-", code: kVK_ANSI_Minus),
        KeyName(name: "Equal", symbol: "=", code: kVK_ANSI_Equal),
        KeyName(name: "LeftBracket", symbol: "[", code: kVK_ANSI_LeftBracket),
        KeyName(name: "RightBracket", symbol: "]", code: kVK_ANSI_RightBracket),
        KeyName(name: "Backslash", symbol: "\\", code: kVK_ANSI_Backslash),
        KeyName(name: "Semicolon", symbol: ";", code: kVK_ANSI_Semicolon),
        KeyName(name: "Quote", symbol: "'", code: kVK_ANSI_Quote),
        KeyName(name: "Comma", symbol: ",", code: kVK_ANSI_Comma),
        KeyName(name: "Period", symbol: ".", code: kVK_ANSI_Period),
        KeyName(name: "Slash", symbol: "/", code: kVK_ANSI_Slash),
        KeyName(name: "Grave", symbol: "`", code: kVK_ANSI_Grave),
    ]
    return keys
}()

enum HotkeyText {
    // In display order, which is also the order Apple uses for ⌃⌥⇧⌘.
    static let modifiers: [(name: String, symbol: String, bit: Int)] =
        [("Ctrl", "⌃", controlKey), ("Option", "⌥", optionKey), ("Shift", "⇧", shiftKey), ("Cmd", "⌘", cmdKey)]
    static let aliases: [String: Int] = [
        "ctrl": controlKey, "control": controlKey,
        "option": optionKey, "opt": optionKey, "alt": optionKey,
        "shift": shiftKey,
        "cmd": cmdKey, "command": cmdKey, "win": cmdKey,
    ]

    static func key(code: UInt32) -> KeyName? { keyNames.first { $0.code == Int(code) } }
    static func isFunctionKey(_ code: UInt32) -> Bool {
        guard let name = key(code: code)?.name else { return false }
        return name.count > 1 && name.hasPrefix("F")
    }

    // "Ctrl+Shift+C" -> Hotkey. Modifiers first, exactly one key last.
    static func parse(_ text: String) -> Hotkey? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var mods: UInt32 = 0
        for (i, part) in parts.enumerated() {
            if let bit = aliases[part.lowercased()] { mods |= UInt32(bit); continue }
            guard i == parts.count - 1, let k = keyNames.first(where: { $0.name.caseInsensitiveCompare(part) == .orderedSame }) else { return nil }
            return Hotkey(keyCode: UInt32(k.code), modifiers: mods)
        }
        return nil
    }

    static func format(_ hotkey: Hotkey) -> String {
        var parts = modifiers.filter { hotkey.modifiers & UInt32($0.bit) != 0 }.map { $0.name }
        parts.append(key(code: hotkey.keyCode)?.name ?? "")
        return parts.joined(separator: "+")
    }

    // "⌃⇧C"; with no key code just the held modifiers, for showing a half-typed combination.
    static func symbols(modifiers mods: UInt32, keyCode: UInt32?) -> String {
        let prefix = modifiers.filter { mods & UInt32($0.bit) != 0 }.map { $0.symbol }.joined()
        guard let keyCode, let k = key(code: keyCode) else { return prefix }
        return prefix + k.symbol
    }

    static func display(_ text: String) -> String {
        guard let hk = parse(text) else { return text }
        return symbols(modifiers: hk.modifiers, keyCode: hk.keyCode)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods = 0
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.command) { mods |= cmdKey }
        return UInt32(mods)
    }
}

// MARK: - Config (Spoco.ini)

struct Settings: Equatable {
    var hotkeys: [Action: String]
    var startAtLogin: Bool
}

enum Config {
    static let startAtLoginKey = "StartAtLogin"

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spoco", isDirectory: true).appendingPathComponent("Spoco.ini")
    }

    // Returns the settings, whether the file should be (re)written, and messages about values that couldn't be read.
    static func load(from url: URL, loginEnabled: Bool) -> (settings: Settings, needsSave: Bool, warnings: [String]) {
        var values: [String: String] = [:]
        let text = try? String(contentsOf: url, encoding: .utf8)
        for raw in (text ?? "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix(";"), !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            values[line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }

        var warnings: [String] = []
        var hotkeys: [Action: String] = [:]
        for action in Action.allCases {
            guard let value = values[action.key.lowercased()] else { hotkeys[action] = action.defaultHotkey; continue }
            if value.isEmpty { hotkeys[action] = ""; continue }
            if let hk = HotkeyText.parse(value) {
                hotkeys[action] = HotkeyText.format(hk)
            } else {
                warnings.append("Can't understand hotkey for \(action.label): \(value)")
                hotkeys[action] = ""
            }
        }

        // Missing means a fresh or hand-written file: keep whatever login item state is already in place.
        let start = values[startAtLoginKey.lowercased()]?.lowercased()
        let startAtLogin = start == "true" ? true : start == "false" ? false : loginEnabled
        return (Settings(hotkeys: hotkeys, startAtLogin: startAtLogin), text == nil || start == nil, warnings)
    }

    static func save(_ settings: Settings, to url: URL) throws {
        var s = "; Spoco hotkeys. Easiest to change from the menu bar icon: Settings...\n"
        s += "; Modifiers: Ctrl, Option, Shift, Cmd. Leave empty to disable.\n"
        for action in Action.allCases { s += "\(action.key)=\(settings.hotkeys[action] ?? "")\n" }
        s += "\n; true or false: launch Spoco when you log in.\n"
        s += "\(startAtLoginKey)=\(settings.startAtLogin)\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Global hotkeys

final class HotkeyCenter {
    static let shared = HotkeyCenter()
    static let signature: OSType = 0x5370_6F63 // 'Spoc'

    var onPress: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr, id.signature == HotkeyCenter.signature, let action = Action(rawValue: Int(id.id) - 1) {
                HotkeyCenter.shared.onPress?(action)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // Exclusive, so another app that registered the same combination exclusively is reported as a conflict.
    func register(_ hotkey: Hotkey, for action: Action) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotkeyCenter.signature, id: UInt32(action.rawValue + 1)) // 0 is not a valid ID
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        return true
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}

// MARK: - Spotify

enum Spotify {
    static let bundleID = "com.spotify.client"
    static let queue = DispatchQueue(label: "Spoco.Spotify")
    static var onPermissionDenied: (() -> Void)?

    static func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    // Does nothing if Spotify isn't running, so a hotkey never launches it.
    static func send(_ action: Action) {
        guard isRunning else { return }
        // Off the main thread: the first send waits for the user to answer macOS's "control Spotify" prompt.
        queue.async {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let eventClass = fourCC("spfy"), eventID = fourCC(action.spotifyEvent)
            let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, eventClass, eventID, true)
            if permission == OSStatus(errAEEventNotPermitted) {
                DispatchQueue.main.async { onPermissionDenied?() }
                return
            }
            guard permission == noErr else { return }
            let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: target,
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            _ = try? event.sendEvent(options: [.noReply], timeout: 2)
        }
    }
}

// MARK: - Start at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Spoco: couldn't change login item: \(error)")
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let configURL = Config.defaultURL
    var settings = Settings(hotkeys: [:], startAtLogin: false)
    var settingsWindow: SettingsWindowController?
    var warnedAboutPermission = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.toolTip = "Spoco - Spotify hotkeys"
        HotkeyCenter.shared.onPress = { Spotify.send($0) }
        Spotify.onPermissionDenied = { [weak self] in self?.permissionDenied() }

        let loaded = Config.load(from: configURL, loginEnabled: LoginItem.isEnabled)
        settings = loaded.settings
        if loaded.needsSave { save() }
        for warning in loaded.warnings { alert(warning) }
        reportConflicts(apply())
    }

    // Opening Spoco.app again while it runs (Finder, Spotlight, Launchpad) opens Settings,
    // so everything stays reachable when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // Registers the current hotkeys and rebuilds the menu. Returns the ones that couldn't be registered.
    func apply() -> [String] {
        LoginItem.set(settings.startAtLogin)
        HotkeyCenter.shared.unregisterAll()
        var failed: [String] = []
        let menu = NSMenu()
        for action in Action.allCases {
            let text = settings.hotkeys[action] ?? ""
            if let hotkey = HotkeyText.parse(text), !HotkeyCenter.shared.register(hotkey, for: action) {
                failed.append("\(action.label) (\(HotkeyText.display(text)))")
            }
            let item = NSMenuItem(title: action.label, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.tag = action.rawValue
            item.target = self
            item.attributedTitle = menuTitle(action.label, shortcut: text.isEmpty ? "(none)" : HotkeyText.display(text))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Spoco", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        return failed
    }

    // Action name on the left, its hotkey right-aligned in grey, like a real shortcut.
    func menuTitle(_ title: String, shortcut: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 150)]
        let s = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: paragraph])
        s.append(NSAttributedString(string: shortcut, attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    @objc func menuCommand(_ sender: NSMenuItem) {
        if let action = Action(rawValue: sender.tag) { Spotify.send(action) }
    }

    @objc func toggleStartAtLogin() {
        settings.startAtLogin = !LoginItem.isEnabled
        save()
        _ = apply()
    }

    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow { window.showWindow(nil); return }

        // Release the hotkeys while recording, otherwise pressing an existing one would trigger it instead.
        HotkeyCenter.shared.unregisterAll()
        let controller = SettingsWindowController(settings: settings)
        controller.onClose = { [weak self] result in
            guard let self else { return }
            if let result {
                self.settings = result
                self.save()
            }
            self.settingsWindow = nil
            self.reportConflicts(self.apply())
        }
        settingsWindow = controller
        controller.showWindow(nil)
    }

    func save() {
        do { try Config.save(settings, to: configURL) }
        catch { alert("Couldn't save settings to \(configURL.path):\n\(error.localizedDescription)") }
    }

    func reportConflicts(_ failed: [String]) {
        guard !failed.isEmpty else { return }
        alert("These hotkeys are already in use by another app:\n\n" + failed.joined(separator: "\n"))
    }

    func permissionDenied() {
        guard !warnedAboutPermission else { return }
        warnedAboutPermission = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Spoco isn't allowed to control Spotify"
        a.informativeText = "Turn on Spotify under Spoco in System Settings → Privacy & Security → Automation, then try the hotkey again."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Spoco"
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }

    // A template glyph of the logo's control tower in a circle; template images follow the menu bar's light/dark look.
    func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.25, dy: 1.25))
            circle.lineWidth = 1.5
            circle.stroke()
            // Tower: mast, cab, shaft.
            NSBezierPath(rect: NSRect(x: 8.4, y: 12.5, width: 1.2, height: 2.5)).fill()
            let cab = NSBezierPath()
            cab.move(to: NSPoint(x: 5.5, y: 12.5)); cab.line(to: NSPoint(x: 12.5, y: 12.5))
            cab.line(to: NSPoint(x: 11, y: 10)); cab.line(to: NSPoint(x: 7, y: 10)); cab.close()
            cab.fill()
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 7.8, y: 10)); shaft.line(to: NSPoint(x: 10.2, y: 10))
            shaft.line(to: NSPoint(x: 10.8, y: 2.5)); shaft.line(to: NSPoint(x: 7.2, y: 2.5)); shaft.close()
            shaft.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((Settings?) -> Void)?
    private var result: Settings?
    private var fields: [Action: HotkeyField] = [:]
    private let startAtLogin = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)

    init(settings: Settings) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Spoco Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let intro = NSTextField(labelWithString: "Click a box and press the key combination you want.")
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for action in Action.allCases {
            let field = HotkeyField()
            field.hotkey = settings.hotkeys[action] ?? ""
            fields[action] = field
            let clear = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
            clear.tag = action.rawValue
            grid.addRow(with: [NSTextField(labelWithString: action.label), field, clear])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        startAtLogin.state = settings.startAtLogin ? .on : .off

        let defaults = NSButton(title: "Defaults", target: self, action: #selector(restoreDefaults))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [defaults, spacer, cancel, save])

        let stack = NSStackView(views: [intro, grid, startAtLogin, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(12, after: intro)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func clear(_ sender: NSButton) {
        guard let action = Action(rawValue: sender.tag), let field = fields[action] else { return }
        field.hotkey = ""
        window?.makeFirstResponder(field)
    }

    @objc func restoreDefaults() {
        for action in Action.allCases { fields[action]?.hotkey = action.defaultHotkey }
    }

    @objc func cancel() { window?.close() }

    @objc func save() {
        var seen: [String: Action] = [:]
        for action in Action.allCases {
            let text = fields[action]!.hotkey
            if text.isEmpty { continue }
            if let other = seen[text.lowercased()] {
                let a = NSAlert()
                a.messageText = "\(other.label) and \(action.label) both use \(HotkeyText.display(text))."
                a.beginSheetModal(for: window!)
                return
            }
            seen[text.lowercased()] = action
        }
        var hotkeys: [Action: String] = [:]
        for action in Action.allCases { hotkeys[action] = fields[action]!.hotkey }
        result = Settings(hotkeys: hotkeys, startAtLogin: startAtLogin.state == .on)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(result)
        onClose = nil
    }
}

// A box that shows whatever key combination is pressed while it has focus.
final class HotkeyField: NSView {
    var hotkey = "" { didSet { message = nil; needsDisplay = true } }
    private var message: String? { didSet { needsDisplay = true } } // half-typed modifiers or a hint
    private var showingModifiers = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var firstBaselineOffsetFromTop: CGFloat { 17 }
    private var isFocused: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { message = nil; return true }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.textBackgroundColor.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.stroke()

        let text: String
        var color = NSColor.secondaryLabelColor
        if let message { text = message }
        else if !hotkey.isEmpty { text = HotkeyText.display(hotkey); color = .labelColor }
        else { text = isFocused ? "Type shortcut" : "(none)" }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    // Combinations with Cmd/Ctrl/Option arrive here before keyDown; take them while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let code = UInt32(event.keyCode)
        let mods = HotkeyText.carbonModifiers(event.modifierFlags)
        if code == UInt32(kVK_Tab) && mods & ~UInt32(shiftKey) == 0 {
            if mods == 0 { window?.selectNextKeyView(self) } else { window?.selectPreviousKeyView(self) }
            return
        }
        showingModifiers = false
        guard HotkeyText.key(code: code) != nil else { message = "Unsupported key"; return }
        // A bare letter or Shift+letter would be swallowed system-wide, so only F-keys may go without Ctrl/Option/Cmd.
        if mods & UInt32(controlKey | optionKey | cmdKey) == 0 && !HotkeyText.isFunctionKey(code) {
            message = "Add Ctrl, Option or Cmd"
            return
        }
        hotkey = HotkeyText.format(Hotkey(keyCode: code, modifiers: mods))
    }

    override func flagsChanged(with event: NSEvent) {
        let mods = HotkeyText.carbonModifiers(event.modifierFlags)
        if mods != 0 {
            showingModifiers = true
            message = HotkeyText.symbols(modifiers: mods, keyCode: nil)
        } else if showingModifiers {
            showingModifiers = false
            message = nil // drop a half-typed "⌃⇧" if no key followed
        }
    }
}

// MARK: - Self-test (run by CI: Spoco --selftest)

enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("FAIL: \(what)") }
        }

        for k in keyNames {
            for mods in [0, controlKey, controlKey | shiftKey, optionKey | cmdKey, controlKey | optionKey | shiftKey | cmdKey] {
                let hk = Hotkey(keyCode: UInt32(k.code), modifiers: UInt32(mods))
                check(HotkeyText.parse(HotkeyText.format(hk)) == hk, "round-trip \(HotkeyText.format(hk))")
            }
        }
        check(Set(keyNames.map { $0.code }).count == keyNames.count, "key codes are unique")
        check(HotkeyText.format(Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey | controlKey | optionKey))) == "Ctrl+Option+Shift+Cmd+C", "modifier order")
        check(HotkeyText.parse(" alt + WIN + control + f9 ") == Hotkey(keyCode: UInt32(kVK_F9), modifiers: UInt32(optionKey | cmdKey | controlKey)), "aliases")
        for bad in ["", "Ctrl+", "Foo", "Ctrl+Foo", "C+Ctrl", "Ctrl+C+D", "Ctrl"] {
            check(HotkeyText.parse(bad) == nil, "reject '\(bad)'")
        }
        check(HotkeyText.display("Ctrl+Shift+C") == "⌃⇧C", "display")
        check(HotkeyText.isFunctionKey(UInt32(kVK_F12)) && !HotkeyText.isFunctionKey(UInt32(kVK_ANSI_F)), "function keys")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spoco-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Spoco.ini")

        var loaded = Config.load(from: url, loginEnabled: true)
        check(loaded.needsSave && loaded.warnings.isEmpty, "missing file needs save")
        check(loaded.settings == Settings(hotkeys: [.playPause: "Ctrl+Shift+C", .next: "Ctrl+Shift+B", .previous: "Ctrl+Shift+Z"], startAtLogin: true), "defaults")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "; comment\n  playpause = cmd+opt+p \nNext=\nPrevious=Hyper+Q\n# other\nstartatlogin=FALSE\n".write(to: url, atomically: true, encoding: .utf8)
        loaded = Config.load(from: url, loginEnabled: true)
        check(loaded.settings.hotkeys[.playPause] == "Option+Cmd+P", "canonical hotkey, got \(loaded.settings.hotkeys[.playPause] ?? "nil")")
        check(loaded.settings.hotkeys[.next] == "", "empty disables")
        check(loaded.settings.hotkeys[.previous] == "" && loaded.warnings.count == 1, "invalid hotkey warns")
        check(loaded.settings.startAtLogin == false && !loaded.needsSave, "StartAtLogin read")

        let settings = Settings(hotkeys: [.playPause: "F8", .next: "Ctrl+Option+Right", .previous: ""], startAtLogin: true)
        do { try Config.save(settings, to: url) } catch { check(false, "save: \(error)") }
        loaded = Config.load(from: url, loginEnabled: false)
        check(loaded.settings == settings && !loaded.needsSave && loaded.warnings.isEmpty, "save/load round-trip")

        print(failures == 0 ? "selftest passed" : "selftest: \(failures) failure(s)")
        return failures == 0
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }

if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    exit(0) // already running
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
