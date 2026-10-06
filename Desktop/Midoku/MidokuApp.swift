import AppKit
import MidokuCore
import SwiftUI

@main
struct MidokuApp: App {
    @NSApplicationDelegateAdaptor(DesktopApplicationDelegate.self) private var applicationDelegate
    @StateObject private var library: LibraryStore
    @StateObject private var sources: SourceStore

    init() {
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _sources = StateObject(wrappedValue: SourceStore(root: library.root.appendingPathComponent("Sources"), library: library))
    }
    @StateObject private var shortcuts = ShortcutStore()

    var body: some Scene {
        Window("Midoku", id: "library") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(sources)
                .frame(minWidth: 720, minHeight: 480)
                .background(WindowLifecycleRegistration(isLibrary: true))
        }
        .defaultSize(width: 1100, height: 760)
        .commands { DesktopCommands(library: library, shortcuts: shortcuts) }

        WindowGroup("Reader", id: "reader", for: UUID.self) { $id in
            Group {
                if let id, let book = library.book(id) {
                    ReaderContainer(book: book)
                        .environmentObject(library)
                        .environmentObject(sources)
                        .environmentObject(shortcuts)
                        .frame(minWidth: 440, minHeight: 360)
                } else {
                    ContentUnavailableView(
                        "Comic Not Available", systemImage: "book.closed",
                        description: Text("This comic was removed from the library."))
                }
            }
            .background(WindowLifecycleRegistration())
        }
        .defaultSize(width: 1000, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)

        Window("Sources", id: "sources") {
            NativeSourceHub().environmentObject(sources).environmentObject(library)
                .frame(minWidth: 720, minHeight: 500)
                .background(WindowLifecycleRegistration())
        }.defaultSize(width: 1100, height: 760)

        Window("Aidoku Library & Backups", id: "aidoku-backup") {
            AidokuBackupLibraryView().environmentObject(library).environmentObject(sources)
                .frame(minWidth: 650, minHeight: 480)
                .background(WindowLifecycleRegistration())
        }.defaultSize(width: 900, height: 700)

        WindowGroup("Manga", id: "manga", for: SourceMangaLink.self) { $link in
            Group {
                if let link {
                    NativeMangaDetails(link: link).environmentObject(sources).environmentObject(library)
                        .frame(minWidth: 600, minHeight: 500)
                }
            }
            .background(WindowLifecycleRegistration())
        }.defaultSize(width: 800, height: 740)

        WindowGroup("Source Website", id: "source-web", for: String.self) { $key in
            Group {
                if let key {
                    NativeSourceWebsite(sourceKey: key).environmentObject(sources).frame(minWidth: 600, minHeight: 480)
                }
            }
            .background(WindowLifecycleRegistration())
        }.defaultSize(width: 1000, height: 760)

        Settings {
            DesktopSettingsView().environmentObject(shortcuts)
                .background(WindowLifecycleRegistration())
        }
    }
}

@MainActor
private final class DesktopApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Explicit Quit must never reopen the library while windows are closing.
        DesktopWindowLifecycle.shared.isTerminating = true
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The role of the last window determines whether to reopen or quit.
        false
    }
}

@MainActor
private final class DesktopWindowLifecycle: NSObject {
    static let shared = DesktopWindowLifecycle()

    private struct Entry {
        weak var window: NSWindow?
        let isLibrary: Bool
        var isClosed = false
    }

    private var windows: [ObjectIdentifier: Entry] = [:]
    private var openLibrary: (() -> Void)?
    private var closeGeneration = 0
    var isTerminating = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func register(_ window: NSWindow, isLibrary: Bool, openLibrary: @escaping () -> Void) {
        windows[ObjectIdentifier(window)] = Entry(window: window, isLibrary: isLibrary)
        self.openLibrary = openLibrary
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let closed = windows[ObjectIdentifier(window)], !closed.isClosed
        else { return }
        windows[ObjectIdentifier(window)]?.isClosed = true
        closeGeneration += 1
        let generation = closeGeneration
        // Let AppKit finish closing before opening another SwiftUI scene.
        DispatchQueue.main.async { [self] in
            guard !isTerminating, generation == closeGeneration else { return }
            windows = windows.filter { $0.value.window != nil }
            guard !windows.values.contains(where: { !$0.isClosed }) else { return }
            if closed.isLibrary {
                NSApp.terminate(nil)
            } else {
                openLibrary?()
            }
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // SwiftUI may reuse a closed window without rebuilding its content view.
        windows[ObjectIdentifier(window)]?.isClosed = false
    }
}

private struct WindowLifecycleRegistration: NSViewRepresentable {
    var isLibrary = false
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> WindowLifecycleView {
        let view = WindowLifecycleView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: WindowLifecycleView, context: Context) {
        configure(view)
    }

    private func configure(_ view: WindowLifecycleView) {
        view.isLibrary = isLibrary
        view.openLibrary = { openWindow(id: "library") }
        view.registerWindow()
    }
}

@MainActor
private final class WindowLifecycleView: NSView {
    var isLibrary = false
    var openLibrary: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindow()
    }

    func registerWindow() {
        guard let window, let openLibrary else { return }
        DesktopWindowLifecycle.shared.register(window, isLibrary: isLibrary, openLibrary: openLibrary)
    }
}

private struct DesktopCommands: Commands {
    @ObservedObject var library: LibraryStore
    @ObservedObject var shortcuts: ShortcutStore
    @FocusedValue(\.readerSession) private var reader
    @Environment(\.openWindow) private var openWindow

    private var readerAcceptsCommands: Bool {
        guard let window = reader?.window, window.isKeyWindow, window.attachedSheet == nil,
            NSApp.modalWindow == nil
        else { return false }
        return !(window.firstResponder is NSTextView) && !(window.firstResponder is NSControl)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Comics…") { library.importPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(library.isImporting || library.loadFailed)
            Button("Show Library") { openWindow(id: "library") }
            Button("Aidoku Library & Backups…") { openWindow(id: "aidoku-backup") }
            Button("Sources…") { openWindow(id: "sources") }
        }
        CommandMenu("Reading") {
            ForEach(ReaderAction.allCases, id: \.self) { action in
                let binding = shortcuts.map.binding(for: action)
                if let binding, !binding.modifiers.intersection([.command, .control]).isEmpty {
                    Button(action.title) { reader?.perform(action) }
                        .keyboardShortcut(binding.equivalent, modifiers: binding.eventModifiers)
                        .disabled(!readerAcceptsCommands)
                } else {
                    Button(
                        "\(action.title)    \(shortcuts.map.bindings(for: action).map(\.display).joined(separator: ", "))"
                    ) { reader?.perform(action) }
                    .disabled(!readerAcceptsCommands)
                }
            }
        }
    }
}
