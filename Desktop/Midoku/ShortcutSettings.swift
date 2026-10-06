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
    func assign(_ binding: KeyBinding, to action: ReaderAction) throws {
        var next = map
        try next.assign(binding, to: action)
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
        let labels = [" ": "Space", "\u{f729}": "Home", "\u{f72b}": "End", "\t": "Tab", "\u{1b}": "Esc"]
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
    @AppStorage("desktop.layout") private var layout = PageLayout.single.rawValue
    @AppStorage("desktop.background") private var background = "dark"

    var body: some View {
        TabView {
            Form {
                Picker("Reading Direction", selection: $direction) {
                    Text("Right to Left").tag(ReadingDirection.rightToLeft.rawValue)
                    Text("Left to Right").tag(ReadingDirection.leftToRight.rawValue)
                }
                Picker("Default Layout", selection: $layout) {
                    Text("Single Page").tag(PageLayout.single.rawValue)
                    Text("Two Pages").tag(PageLayout.spread.rawValue)
                    Text("Continuous").tag(PageLayout.continuous.rawValue)
                }
                Picker("Reader Background", selection: $background) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                Text("Defaults apply to newly opened readers. Each window keeps its own layout and zoom.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .tabItem { Label("Reading", systemImage: "book") }

            VStack(alignment: .leading, spacing: 12) {
                Text("Click a shortcut, then press its new key combination. Press Escape to cancel.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(ReaderAction.allCases, id: \.self) { action in
                            HStack {
                                Text(action.title)
                                Spacer()
                                if recording == action {
                                    ShortcutRecorder { binding in
                                        recording = nil
                                        guard let binding else { return }
                                        do { try shortcuts.assign(binding, to: action) } catch ShortcutError.conflict(
                                            let other)
                                        { errorMessage = "This shortcut is already assigned to \(other.title)." } catch
                                        {
                                            errorMessage =
                                                "This key combination is reserved for standard macOS or arrow-key navigation."
                                        }
                                    }
                                    .frame(width: 150, height: 26)
                                } else {
                                    Button(shortcuts.map.binding(for: action).display) { recording = action }
                                        .frame(width: 150)
                                        .accessibilityLabel(
                                            "\(action.title): \(shortcuts.map.binding(for: action).display)")
                                }
                            }
                        }
                    }.padding(4)
                }
                Text("← and → follow the reading direction. Standard macOS shortcuts such as ⌘W and ⌘Q are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore Defaults") {
                    recording = nil
                    shortcuts.reset()
                }
            }
            .padding(24)
            .tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        .frame(width: 580, height: 540)
        .alert(
            "Shortcut Unavailable",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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
