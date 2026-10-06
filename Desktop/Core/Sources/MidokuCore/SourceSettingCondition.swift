import Foundation

public enum SourceSettingCondition {
    /// Aidoku setting requirements allow key presence, equality and conjunction.
    public static func evaluate(_ expression: String, namespace: String, value: (String) -> String?) -> Bool {
        expression.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.allSatisfy { statement in
                let parts = statement.components(separatedBy: "==").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let key = parts.first, !key.isEmpty else { return false }
                if key == "true" { return true }
                let stored = value(namespace + "." + key)
                if parts.count == 2 { return stored == parts[1] }
                guard parts.count == 1 else { return false }
                return stored != nil && stored != "0"
            }
    }
}
