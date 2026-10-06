import Foundation

public enum ReaderAction: String, CaseIterable, Codable, Sendable {
    case nextPage, previousPage, nextScreen, previousScreen, firstPage, lastPage
    case zoomIn, zoomOut, actualSize, fitPage, fitWidth, increaseWidth, decreaseWidth
    case toggleChrome, toggleThumbnails, toggleOverview, readingSettings, toggleFullScreen, showLibrary

    public var allowsRepeat: Bool {
        switch self {
        case .nextPage, .previousPage, .nextScreen, .previousScreen, .zoomIn, .zoomOut, .increaseWidth, .decreaseWidth:
            true
        default: false
        }
    }
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
        return key == "\t" || key == "\u{1b}"
            || (modifiers.contains(.command) && systemKeys.contains(key))
    }
}

public struct ShortcutMap: Codable, Equatable, Sendable {
    public private(set) var overrides: [ReaderAction: [KeyBinding]] = [:]
    public init() {}
    public static let defaults: [ReaderAction: [KeyBinding]] = [
        .previousPage: ["a", "\u{f702}", "\u{f700}"].map { .init(key: $0) },
        .nextPage: ["d", "\u{f703}", "\u{f701}"].map { .init(key: $0) },
        .nextScreen: [.init(key: " "), .init(key: "\u{f72d}")],
        .previousScreen: [.init(key: " ", modifiers: .shift), .init(key: "\u{f72c}")],
        .firstPage: [.init(key: "\u{f729}")], .lastPage: [.init(key: "\u{f72b}")],
        .zoomIn: [.init(key: "=", modifiers: .command)], .zoomOut: [.init(key: "-", modifiers: .command)],
        .actualSize: [.init(key: "0", modifiers: .command)], .fitPage: [.init(key: "1", modifiers: .command)],
        .fitWidth: [.init(key: "2", modifiers: .command)],
        .increaseWidth: [.init(key: "]")], .decreaseWidth: [.init(key: "[")],
        .toggleChrome: [.init(key: "q")], .toggleThumbnails: [.init(key: "t")],
        .toggleOverview: [.init(key: "f")], .readingSettings: [.init(key: "r")],
        .toggleFullScreen: [.init(key: "f", modifiers: [.control, .command])],
        .showLibrary: [.init(key: "l", modifiers: .command)],
    ]

    public func bindings(for action: ReaderAction) -> [KeyBinding] {
        if let override = overrides[action] { return override }
        // Explicit custom bindings win over defaults introduced by an upgrade.
        let claimed = Set(overrides.values.flatMap { $0 })
        return (Self.defaults[action] ?? []).filter { !claimed.contains($0) }
    }
    public func binding(for action: ReaderAction) -> KeyBinding? { bindings(for: action).first }
    public func action(for binding: KeyBinding) -> ReaderAction? {
        ReaderAction.allCases.first { bindings(for: $0).contains(binding) }
    }
    public mutating func assign(_ binding: KeyBinding, to action: ReaderAction) throws {
        try validate(binding, for: action)
        overrides[action] = [binding]
    }
    public mutating func add(_ binding: KeyBinding, to action: ReaderAction) throws {
        try validate(binding, for: action)
        var list = bindings(for: action)
        if !list.contains(binding) { list.append(binding) }
        overrides[action] = list
    }
    public mutating func remove(_ binding: KeyBinding, from action: ReaderAction) {
        overrides[action] = bindings(for: action).filter { $0 != binding }
    }
    public mutating func unbind(_ action: ReaderAction) { overrides[action] = [] }
    public mutating func reset() { overrides = [:] }
    private func validate(_ binding: KeyBinding, for action: ReaderAction) throws {
        guard binding.key.count == 1, !binding.isReserved else { throw ShortcutError.reserved }
        if let other = self.action(for: binding), other != action { throw ShortcutError.conflict(other) }
    }
    private enum CodingKeys: String, CodingKey { case version, overrides }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try container.decodeIfPresent(Int.self, forKey: .version) {
            guard version == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version, in: container, debugDescription: "Unknown shortcut version")
            }
            overrides = try container.decode([ReaderAction: [KeyBinding]].self, forKey: .overrides)
        } else {
            let legacy = try container.decode([ReaderAction: KeyBinding].self, forKey: .overrides)
            overrides = legacy.mapValues { [$0] }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encode(overrides, forKey: .overrides)
    }
}

public enum ShortcutError: Error, Equatable {
    case reserved
    case conflict(ReaderAction)
}
