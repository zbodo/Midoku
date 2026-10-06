import AppKit
import MidokuCore
import SwiftUI

@main
struct MidokuApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var sources: SourceStore

    init() {
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _sources = StateObject(wrappedValue: SourceStore(root: library.root.appendingPathComponent("Sources")))
    }
    @StateObject private var shortcuts = ShortcutStore()

    var body: some Scene {
        Window("Midoku", id: "library") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(sources)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { DesktopCommands(library: library, shortcuts: shortcuts) }

        WindowGroup("Reader", id: "reader", for: UUID.self) { $id in
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
        .defaultSize(width: 1000, height: 800)

        Window("Sources", id: "sources") {
            NativeSourceHub().environmentObject(sources).environmentObject(library)
                .frame(minWidth: 720, minHeight: 500)
        }.defaultSize(width: 1100, height: 760)

        WindowGroup("Manga", id: "manga", for: SourceMangaLink.self) { $link in
            if let link {
                NativeMangaDetails(link: link).environmentObject(sources).environmentObject(library)
                    .frame(minWidth: 600, minHeight: 500)
            }
        }.defaultSize(width: 800, height: 740)

        WindowGroup("Source Website", id: "source-web", for: String.self) { $key in
            if let key {
                NativeSourceWebsite(sourceKey: key).environmentObject(sources).frame(minWidth: 600, minHeight: 480)
            }
        }.defaultSize(width: 1000, height: 760)

        Settings {
            DesktopSettingsView().environmentObject(shortcuts)
        }
    }
}

private struct DesktopCommands: Commands {
    @ObservedObject var library: LibraryStore
    @ObservedObject var shortcuts: ShortcutStore
    @FocusedValue(\.readerSession) private var reader
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Comics…") { library.importPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(library.isImporting || library.loadFailed)
            Button("Show Library") { openWindow(id: "library") }
            Button("Sources…") { openWindow(id: "sources") }
        }
        CommandMenu("Reading") {
            ForEach(ReaderAction.allCases, id: \.self) { action in
                let binding = shortcuts.map.binding(for: action)
                if !binding.modifiers.intersection([.command, .control]).isEmpty {
                    Button(action.title) { reader?.perform(action) }
                        .keyboardShortcut(binding.equivalent, modifiers: binding.eventModifiers)
                        .disabled(reader == nil)
                } else {
                    Button("\(action.title)    \(binding.display)") { reader?.perform(action) }
                        .disabled(reader == nil)
                }
            }
        }
    }
}
