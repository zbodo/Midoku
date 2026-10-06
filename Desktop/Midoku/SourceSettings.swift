import AidokuRunner
import Combine
import MidokuCore
import SwiftUI

struct NativeSourceSettings: View {
    let source: AidokuRunner.Source
    @Environment(\.dismiss) private var dismiss
    @State private var preferencesRevision = 0
    @State private var settings: [AidokuRunner.Setting] = []
    @State private var error: String?
    var body: some View {
        VStack {
            HStack {
                Text(source.name).font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Form {
                ForEach(Array(settings.enumerated()), id: \.offset) { _, setting in
                    SourceSettingRow(source: source, setting: setting, preferencesRevision: preferencesRevision)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }.frame(width: 580, height: 580)
            .onReceive(
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            ) { _ in
                preferencesRevision += 1
            }
            .task { do { settings = try await source.getSettings() } catch { self.error = error.localizedDescription } }
    }
}

private struct SourceSettingRow: View {
    let source: AidokuRunner.Source
    let setting: AidokuRunner.Setting
    let preferencesRevision: Int
    init(source: AidokuRunner.Source, setting: AidokuRunner.Setting, preferencesRevision: Int = 0) {
        self.source = source
        self.setting = setting
        self.preferencesRevision = preferencesRevision
    }
    @Environment(\.openWindow) private var openWindow
    @State private var revision = 0
    @State private var error: String?
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    private var key: String { source.key + "." + setting.key }
    private var enabled: Bool {
        func matches(_ expression: String) -> Bool {
            SourceSettingCondition.evaluate(expression, namespace: source.key) {
                UserDefaults.standard.string(forKey: $0)
            }
        }
        if let requires = setting.requires, !matches(requires) { return false }
        if let requires = setting.requiresFalse, matches(requires) { return false }
        return true
    }
    private func binding<T>(
        _ get: @escaping @MainActor @Sendable () -> T,
        _ set: @escaping @MainActor @Sendable (T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { value in
                set(value)
                revision += 1
                notify()
            })
    }
    private var text: Binding<String> {
        binding({ SettingsStore.shared.get(key: key) }, { SettingsStore.shared.set(key: key, value: $0) })
    }
    private var flag: Binding<Bool> {
        binding({ SettingsStore.shared.get(key: key) }, { SettingsStore.shared.set(key: key, value: $0) })
    }
    private var number: Binding<Double> {
        binding({ SettingsStore.shared.get(key: key) }, { SettingsStore.shared.set(key: key, value: $0) })
    }
    private var integer: Binding<Int> {
        binding({ SettingsStore.shared.get(key: key) }, { SettingsStore.shared.set(key: key, value: $0) })
    }
    var body: some View {
        VStack(alignment: .leading) {
            content.disabled(!enabled || busy)
                .onChange(of: revision) { _, _ in }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }
    @ViewBuilder private var content: some View {
        switch setting.value {
        case .group(let value):
            GroupBox(setting.title) {
                children(value.items)
                if let footer = value.footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
            }
        case .page(let value):
            DisclosureGroup(setting.title) { children(value.items) }
        case .select(let value): selection(value.values, titles: value.titles)
        case .picker(let value): selection(value.values, titles: value.titles)
        case .multiselect(let value):
            VStack(alignment: .leading) {
                Text(setting.title).font(.headline)
                ForEach(value.values.indices, id: \.self) { index in
                    Toggle(
                        value.titles.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? value.values[index],
                        isOn: binding(
                            {
                                let selected: [String] = SettingsStore.shared.get(key: key)
                                return selected.contains(value.values[index])
                            },
                            { checked in
                                var selected: [String] = SettingsStore.shared.get(key: key)
                                selected.removeAll { $0 == value.values[index] }
                                if checked { selected.append(value.values[index]) }
                                SettingsStore.shared.set(key: key, value: selected)
                            }))
                }
            }
        case .toggle: Toggle(setting.title, isOn: flag)
        case .text(let value):
            if value.secure == true {
                SecureField(setting.title, text: text)
            } else {
                TextField(setting.title, text: text)
            }
        case .stepper(let value):
            Stepper(
                setting.title + ": " + number.wrappedValue.formatted(), value: number,
                in: value.minimumValue...value.maximumValue, step: value.stepValue ?? 1)
        case .segment(let value):
            Picker(setting.title, selection: integer) {
                ForEach(value.options.indices, id: \.self) { Text(value.options[$0]).tag($0) }
            }
        case .editableList:
            TextField(
                setting.title,
                text: binding(
                    {
                        let values: [String] = SettingsStore.shared.get(key: key)
                        return values.joined(separator: "\n")
                    },
                    {
                        SettingsStore.shared.set(key: key, value: $0.split(separator: "\n").map(String.init))
                    }), axis: .vertical
            ).lineLimit(3...8)
        case .button: Button(setting.title) { notify() }
        case .link(let value):
            if let url = URL(string: value.url) { Link(setting.title, destination: url) }
        case .login(let value):
            if value.method == .basic {
                GroupBox(setting.title) {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    Button("Sign In") {
                        busy = true
                        Task {
                            defer {
                                busy = false
                                password = ""
                            }
                            do {
                                let ok = try await source.handleBasicLogin(
                                    key: setting.key, username: username, password: password)
                                error = ok ? nil : "Sign in failed."
                                if ok {
                                    try SourceCredentials.save(
                                        sourceKey: source.key, key: key, username: username, password: password)
                                    SettingsStore.shared.set(key: key, value: "logged_in")
                                }
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(username.isEmpty || password.isEmpty)
                }
            } else {
                Button(setting.title) { openWindow(id: "source-web", value: source.key) }
                if value.method == .oauth {
                    Text("OAuth callback sign-in is not supported yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if SettingsStore.shared.object(key: key) != nil {
                Button("Sign Out", role: .destructive) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try SourceCredentials.remove(sourceKey: source.key, key: key)
                            SettingsStore.shared.remove(key: key)
                            SettingsStore.shared.remove(key: key + ".keys")
                            SettingsStore.shared.remove(key: key + ".values")
                            for name in value.localStorageKeys ?? [] {
                                SettingsStore.shared.remove(key: key + ".ls." + name)
                            }
                            if value.clearCookiesOnLogOut == true { await source.clearCache() }
                            username = ""
                            password = ""
                            revision += 1
                            notify()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        case .custom: Text(setting.title).foregroundStyle(.secondary)
        }
    }
    private func selection(_ values: [String], titles: [String]?) -> some View {
        Picker(setting.title, selection: text) {
            ForEach(values.indices, id: \.self) { index in
                Text(titles.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? values[index]).tag(
                    values[index])
            }
        }
    }
    private func children(_ values: [AidokuRunner.Setting]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                AnyView(SourceSettingRow(source: source, setting: item, preferencesRevision: preferencesRevision))
            }
        }
    }
    private func notify() {
        guard let notification = setting.notification else { return }
        Task {
            do { try await source.handleNotification(notification: notification) } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
