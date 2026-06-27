import Foundation

/// Minimal, dependency-free reader for the one thing the engine needs out of
/// `~/.ticket/config.yaml`: `projects[<project>].path`. The file is a flat, space-indented
/// map written by tk; a full YAML parser would be over-engineering for a single lookup.
enum RepoResolver {
    static func repoPath(forProject project: String, inYAML yaml: String) -> String? {
        let lines = yaml.components(separatedBy: "\n")

        // Find the top-level `projects:` block.
        var start = -1
        for (i, line) in lines.enumerated() where indent(line) == 0 && trimmed(line) == "projects:" {
            start = i + 1
            break
        }
        guard start >= 0 else { return nil }

        // The indent of the first child fixes the per-project key depth.
        var childIndent = -1
        for i in start..<lines.count {
            if trimmed(lines[i]).isEmpty { continue }
            let ind = indent(lines[i])
            if ind == 0 { return nil }
            childIndent = ind
            break
        }
        guard childIndent > 0 else { return nil }

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
            guard String(key.dropLast()) == project else { continue }

            // Scan this project's deeper-indented body for `path:`.
            while i < lines.count {
                let body = lines[i]
                if trimmed(body).isEmpty { i += 1; continue }
                if indent(body) <= childIndent { break }
                let t = trimmed(body)
                if t.hasPrefix("path:") {
                    let value = t.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
                    return unquote(value)
                }
                i += 1
            }
            return nil
        }
        return nil
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
