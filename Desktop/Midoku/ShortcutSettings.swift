import AppKit
import MidokuCore
import SwiftUI

@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var map: ShortcutMap
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        map =
            defaults.data(forKey: "desktop.shortcuts").flatMap { try? JSONDecoder().decode(ShortcutMap.self, from: $0) }
            ?? ShortcutMap()
    }
    func add(_ binding: KeyBinding, to action: ReaderAction) throws {
        var next = map
        try next.add(binding, to: action)
        try persist(next)
    }
    func remove(_ binding: KeyBinding, from action: ReaderAction) {
        var next = map
        next.remove(binding, from: action)
        try? persist(next)
    }
    func unbind(_ action: ReaderAction) {
        var next = map
        next.unbind(action)
        try? persist(next)
    }
    private func persist(_ next: ShortcutMap) throws {
        defaults.set(try JSONEncoder().encode(next), forKey: "desktop.shortcuts")
        map = next
    }
    func reset() {
        map.reset()
        defaults.removeObject(forKey: "desktop.shortcuts")
    }
}

extension KeyBinding {
    init(event: NSEvent) {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        self.init(key: event.charactersIgnoringModifiers ?? "", modifiers: modifiers)
    }
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
    var display: String {
        let labels = [
            " ": "Space", "\u{f729}": "Home", "\u{f72b}": "End", "\t": "Tab", "\u{1b}": "Esc",
            "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→",
            "\u{f72c}": "Page Up", "\u{f72d}": "Page Down",
        ]
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
            + (labels[key] ?? key.uppercased())
    }
    var equivalent: KeyEquivalent { KeyEquivalent(key.first ?? " ") }
}

struct DesktopSettingsView: View {
    @EnvironmentObject private var shortcuts: ShortcutStore
    @State private var recording: ReaderAction?
    @State private var errorMessage: String?
    @AppStorage("desktop.direction") private var direction = ReadingDirection.rightToLeft.rawValue
    @AppStorage("desktop.layout") private var layout = PageLayout.adaptive.rawValue
    @AppStorage("desktop.background") private var background = "dark"

    var body: some View {
        TabView {
            Form {
                Picker("Reading Direction", selection: $direction) {
                    Text("Right to Left").tag(ReadingDirection.rightToLeft.rawValue)
                    Text("Left to Right").tag(ReadingDirection.leftToRight.rawValue)
                }
                Picker("Default Layout", selection: $layout) {
                    Text("Adaptive Pages").tag(PageLayout.adaptive.rawValue)
                    Text("Continuous").tag(PageLayout.continuous.rawValue)
                }
                Picker("Reader Background", selection: $background) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                ReaderInputSettings()
                Text("Defaults apply to newly opened readers. Each window keeps its own layout and zoom.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .tabItem { Label("Reading", systemImage: "book") }

            keyboardSettings
                .padding(24)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        .onAppear { layout = PageLayout.preference(layout).rawValue }
        .frame(width: 740, height: 620)
        .alert(
            "Shortcut Unavailable",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    private var keyboardSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add multiple shortcuts to an action, or remove them to leave it unbound. Escape cancels recording.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(ReaderAction.allCases, id: \.self) { action in shortcutRow(action) }
                }.padding(4)
            }
            Text(
                "eHunter-style keys: A / D navigate pages, Q toggles controls, T toggles thumbnails, F opens the page overview. Standard macOS shortcuts are preserved."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Restore Defaults") {
                recording = nil
                shortcuts.reset()
            }
        }
    }
    private func shortcutRow(_ action: ReaderAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(action.title)
                Spacer()
                Button("Add Shortcut…") { recording = action }
                Button("Unbind") { shortcuts.unbind(action) }
                    .disabled(shortcuts.map.bindings(for: action).isEmpty)
            }
            HStack {
                ForEach(shortcuts.map.bindings(for: action), id: \.self) { binding in
                    Button {
                        shortcuts.remove(binding, from: action)
                    } label: {
                        HStack(spacing: 6) {
                            Text(binding.display)
                            Image(systemName: "xmark").font(.caption2)
                        }
                    }.help("Remove Shortcut")
                }
                if recording == action {
                    ShortcutRecorder { binding in
                        recording = nil
                        guard let binding else { return }
                        do { try shortcuts.add(binding, to: action) } catch ShortcutError.conflict(let other) {
                            errorMessage = "This shortcut is already assigned to \(other.title)."
                        } catch { errorMessage = "This key combination is reserved for standard macOS navigation." }
                    }.frame(width: 170, height: 26)
                } else if shortcuts.map.bindings(for: action).isEmpty {
                    Text("Unbound").foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let onRecord: (KeyBinding?) -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        return view
    }
    func updateNSView(_ nsView: RecorderView, context: Context) { nsView.onRecord = onRecord }
    static func dismantleNSView(_ nsView: RecorderView, coordinator: ()) { nsView.stop() }
    final class RecorderView: NSView {
        var onRecord: ((KeyBinding?) -> Void)?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            window?.makeFirstResponder(self)
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.firstResponder === self else { return event }
                self.keyDown(with: event)
                return nil
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            (String(localized: "Press a shortcut…") as NSString).draw(
                at: NSPoint(x: 8, y: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { onRecord?(nil) } else { onRecord?(KeyBinding(event: event)) }
        }
        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
