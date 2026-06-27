import Foundation

/// Minimal, dependency-free reader for `~/.ticket/config.yaml` (a flat, space-indented map
/// written by tk): `central_root` and `projects[<name>].path`. A full YAML parser would be
/// over-engineering for these lookups.
enum RepoResolver {
    static func repoPath(forProject project: String, inYAML yaml: String) -> String? {
        projects(inYAML: yaml)[project]
    }

    static func centralRoot(inYAML yaml: String) -> String? {
        for line in yaml.components(separatedBy: "\n") where indent(line) == 0 {
            let t = trimmed(line)
            if t.hasPrefix("central_root:") {
                return unquote(t.dropFirst("central_root:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// All `projects[<name>].path` entries.
    static func projects(inYAML yaml: String) -> [String: String] {
        let lines = yaml.components(separatedBy: "\n")
        var result: [String: String] = [:]

        // Find the top-level `projects:` block.
        var start = -1
        for (i, line) in lines.enumerated() where indent(line) == 0 && trimmed(line) == "projects:" {
            start = i + 1
            break
        }
        guard start >= 0 else { return result }

        // The indent of the first child fixes the per-project key depth.
        var childIndent = -1
        for i in start..<lines.count {
            if trimmed(lines[i]).isEmpty { continue }
            let ind = indent(lines[i])
            if ind == 0 { return result }
            childIndent = ind
            break
        }
        guard childIndent > 0 else { return result }

        var i = start
        while i < lines.count {
            let line = lines[i]
            i += 1
            if trimmed(line).isEmpty { continue }
            let ind = indent(line)
            if ind == 0 { break }
            guard ind == childIndent else { continue }

            let key = trimmed(line)
            guard key.hasSuffix(":") else { continue }
            let name = String(key.dropLast())

            // Scan this project's deeper-indented body for `path:`.
            while i < lines.count {
                let body = lines[i]
                if trimmed(body).isEmpty { i += 1; continue }
                if indent(body) <= childIndent { break }
                let t = trimmed(body)
                if t.hasPrefix("path:"), result[name] == nil {  // first-wins on duplicate keys
                    result[name] = unquote(t.dropFirst("path:".count).trimmingCharacters(in: .whitespaces))
                }
                i += 1
            }
        }
        return result
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, let first = value.first, let last = value.last,
           first == last, first == "\"" || first == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
