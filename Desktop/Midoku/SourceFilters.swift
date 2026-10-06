import AidokuRunner
import SwiftUI

struct NativeSourceFilters: View {
    let source: AidokuRunner.Source
    let apply: ([AidokuRunner.FilterValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filters: [AidokuRunner.Filter] = []
    @State private var values: [String: AidokuRunner.FilterValue] = [:]
    @State private var error: String?
    var body: some View {
        VStack {
            HStack {
                Text("Search Filters").font(.title2)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    apply(filters.compactMap { values[$0.id] })
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }.padding()
            Form {
                ForEach(filters, id: \.id) { filter in
                    SourceFilterRow(
                        filter: filter, value: Binding(get: { values[filter.id] }, set: { values[filter.id] = $0 }))
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }.frame(width: 600, height: 600)
            .task {
                do {
                    filters = try await source.getSearchFilters()
                    for filter in filters {
                        switch filter.value {
                        case .select(let select):
                            if let value = select.defaultValue {
                                values[filter.id] = .select(id: filter.id, value: value)
                            }
                        case .multiselect(let select):
                            values[filter.id] = .multiselect(
                                id: filter.id, included: select.defaultIncluded ?? [],
                                excluded: select.defaultExcluded ?? [])
                        case .sort(_, _, let value):
                            if let value {
                                values[filter.id] = .sort(
                                    .init(id: filter.id, index: value.index, ascending: value.ascending))
                            }
                        case .check(_, _, let checked):
                            if let checked { values[filter.id] = .check(id: filter.id, value: checked ? 1 : 0) }
                        default: break
                        }
                    }
                } catch { self.error = error.localizedDescription }
            }
    }
}

private struct SourceFilterRow: View {
    let filter: AidokuRunner.Filter
    @Binding var value: AidokuRunner.FilterValue?
    private var title: String { filter.title ?? filter.id }
    private func text() -> String {
        if case .text(_, let text) = value { return text }
        return ""
    }
    private func selected() -> String {
        if case .select(_, let key) = value { return key }
        return ""
    }
    private func check() -> Int {
        if case .check(_, let checked) = value { return checked }
        return 0
    }
    private func sort() -> AidokuRunner.SortFilterValue {
        if case .sort(let sort) = value { return sort }
        return .init(id: filter.id, index: 0, ascending: false)
    }
    private func id(_ index: Int, ids: [String]?, options: [String]) -> String {
        ids.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? options[index]
    }
    @ViewBuilder var body: some View {
        switch filter.value {
        case .note(let note): Text(note).foregroundStyle(.secondary)
        case .text(let placeholder):
            TextField(
                placeholder ?? title, text: Binding(get: { text() }, set: { value = .text(id: filter.id, value: $0) }))
        case .check(let name, let canExclude, _):
            Picker(
                name ?? title, selection: Binding(get: { check() }, set: { value = .check(id: filter.id, value: $0) })
            ) {
                Text("Any").tag(0)
                Text("Include").tag(1)
                if canExclude { Text("Exclude").tag(2) }
            }
        case .select(let select):
            Picker(
                title,
                selection: Binding(
                    get: { selected() }, set: { value = $0.isEmpty ? nil : .select(id: filter.id, value: $0) })
            ) {
                Text("Any").tag("")
                ForEach(select.options.indices, id: \.self) { index in
                    Text(select.options[index]).tag(id(index, ids: select.ids, options: select.options))
                }
            }
        case .sort(let canAscend, let options, _):
            Picker(
                title,
                selection: Binding(
                    get: { Int(sort().index) },
                    set: { value = .sort(.init(id: filter.id, index: $0, ascending: sort().ascending)) })
            ) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
            if canAscend {
                Toggle(
                    "Ascending",
                    isOn: Binding(
                        get: { sort().ascending },
                        set: { value = .sort(.init(id: filter.id, index: Int(sort().index), ascending: $0)) }))
            }
        case .multiselect(let select):
            DisclosureGroup(title) {
                ForEach(select.options.indices, id: \.self) { index in
                    let key = id(index, ids: select.ids, options: select.options)
                    Picker(
                        select.options[index],
                        selection: Binding(
                            get: {
                                if case .multiselect(_, let included, let excluded) = value {
                                    return included.contains(key) ? 1 : excluded.contains(key) ? 2 : 0
                                }
                                return 0
                            },
                            set: { choice in
                                var included: [String] = []
                                var excluded: [String] = []
                                if case .multiselect(_, let i, let e) = value {
                                    included = i
                                    excluded = e
                                }
                                included.removeAll { $0 == key }
                                excluded.removeAll { $0 == key }
                                if choice == 1 { included.append(key) }
                                if choice == 2 { excluded.append(key) }
                                value = .multiselect(id: filter.id, included: included, excluded: excluded)
                            })
                    ) {
                        Text("Any").tag(0)
                        Text("Include").tag(1)
                        if select.canExclude { Text("Exclude").tag(2) }
                    }
                }
            }
        case .range(let minimum, let maximum, let decimal):
            HStack {
                Text(title)
                rangeField("From", from: true, minimum: minimum, maximum: maximum, decimal: decimal)
                rangeField("To", from: false, minimum: minimum, maximum: maximum, decimal: decimal)
            }
        }
    }
    private func rangeField(_ label: String, from: Bool, minimum: Float?, maximum: Float?, decimal: Bool) -> some View {
        TextField(
            label,
            text: Binding(
                get: {
                    if case .range(_, let lower, let upper) = value, let number = from ? lower : upper {
                        return String(number)
                    }
                    return ""
                },
                set: { text in
                    var lower: Float?
                    var upper: Float?
                    if case .range(_, let l, let u) = value {
                        lower = l
                        upper = u
                    }
                    var number = Float(text)
                    if let raw = number {
                        number = min(
                            max(decimal ? raw : raw.rounded(), minimum ?? -.greatestFiniteMagnitude),
                            maximum ?? .greatestFiniteMagnitude)
                    }
                    if from { lower = number } else { upper = number }
                    value = .range(id: filter.id, from: lower, to: upper)
                })
        ).textFieldStyle(.roundedBorder)
    }
}
