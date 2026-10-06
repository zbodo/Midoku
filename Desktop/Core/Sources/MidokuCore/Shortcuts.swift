import Foundation

public enum ReaderAction: String, CaseIterable, Codable, Sendable {
    case nextPage, previousPage, firstPage, lastPage
    case zoomIn, zoomOut, actualSize, fitPage, fitWidth
    case toggleChrome, toggleFullScreen, showLibrary
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let control = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
}

public struct KeyBinding: Codable, Hashable, Sendable {
    public let key: String
    public let modifiers: KeyModifiers
    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public var isReserved: Bool {
        let systemKeys: Set<String> = ["q", "w", "h", "m", "o", ",", "\t"]
        return key == "\t" || key == "\u{1b}" || ["\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}"].contains(key)
            || (modifiers.contains(.command) && systemKeys.contains(key))
    }
}

public struct ShortcutMap: Codable, Equatable, Sendable {
    public private(set) var overrides: [ReaderAction: KeyBinding] = [:]
    public init() {}

    public static let defaults: [ReaderAction: KeyBinding] = [
        .nextPage: .init(key: " "), .previousPage: .init(key: " ", modifiers: .shift),
        .firstPage: .init(key: "\u{f729}"), .lastPage: .init(key: "\u{f72b}"),
        .zoomIn: .init(key: "=", modifiers: .command), .zoomOut: .init(key: "-", modifiers: .command),
        .actualSize: .init(key: "0", modifiers: .command), .fitPage: .init(key: "1", modifiers: .command),
        .fitWidth: .init(key: "2", modifiers: .command), .toggleChrome: .init(key: "t"),
        .toggleFullScreen: .init(key: "f", modifiers: [.control, .command]),
        .showLibrary: .init(key: "l", modifiers: .command),
    ]

    public func binding(for action: ReaderAction) -> KeyBinding {
        overrides[action] ?? Self.defaults[action]!
    }

    public func action(for binding: KeyBinding) -> ReaderAction? {
        ReaderAction.allCases.first { self.binding(for: $0) == binding }
    }

    public mutating func assign(_ binding: KeyBinding, to action: ReaderAction) throws {
        guard binding.key.count == 1, !binding.isReserved else { throw ShortcutError.reserved }
        if let conflict = self.action(for: binding), conflict != action { throw ShortcutError.conflict(conflict) }
        overrides[action] = binding
    }

    public mutating func reset() { overrides = [:] }
}

public enum ShortcutError: Error, Equatable {
    case reserved
    case conflict(ReaderAction)
}
