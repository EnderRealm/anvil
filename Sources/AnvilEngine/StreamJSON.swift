import Foundation

/// One line of `--output-format stream-json`. Every field is optional so an unknown or
/// partially-shaped event never fails the decode; the dispatcher keys off `type`.
struct StreamLine: Decodable {
    let type: String?
    let subtype: String?
    let session_id: String?
    let model: String?
    let cwd: String?
    let message: AssistantMessage?
    let rate_limit_info: RateLimitInfo?
    let result: String?
    let is_error: Bool?
    let terminal_reason: String?
    let total_cost_usd: Double?
    let usage: TokenUsage?
}

struct AssistantMessage: Decodable {
    struct Block: Decodable {
        let type: String?
        let text: String?
    }
    let content: [Block]?

    /// Concatenated text blocks (ignores thinking/tool blocks).
    var text: String {
        (content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
}

struct TokenUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
}

/// The sentinel block anvil parses out of the final `result.result` text.
enum Sentinel: Equatable {
    case needsInput(question: String, options: [String])
    case done(summary: String?)

    /// Outcome of scanning for a sentinel. `malformed` (marker present but unparseable JSON)
    /// is kept distinct from `none` so a blocked turn is never silently treated as done.
    enum Scan: Equatable {
        case none
        case malformed
        case value(Sentinel)
    }

    static let needsInputMarker = "<<<ANVIL:NEEDS_INPUT>>>"
    static let doneMarker = "<<<ANVIL:DONE>>>"
    static let endMarker = "<<<ANVIL:END>>>"

    private struct NeedsInputPayload: Decodable {
        let question: String
        let options: [String]?
    }
    private struct DonePayload: Decodable {
        let summary: String?
    }

    /// Lenient parse: Opus may prepend prose, so scan for the LAST marker (not a prefix
    /// match), then decode the JSON between it and an optional closing `<<<ANVIL:END>>>`.
    static func parse(_ text: String) -> Scan {
        let needs = text.range(of: needsInputMarker, options: .backwards)
        let done = text.range(of: doneMarker, options: .backwards)

        // Pick whichever marker appears later in the string.
        let useNeeds: Bool
        switch (needs, done) {
        case (let n?, let d?): useNeeds = n.lowerBound >= d.lowerBound
        case (.some, nil): useNeeds = true
        case (nil, .some): useNeeds = false
        case (nil, nil): return .none
        }

        let markerEnd = useNeeds ? needs!.upperBound : done!.upperBound
        let tail = text[markerEnd...]
        let jsonSlice: Substring
        if let end = tail.range(of: endMarker) {
            jsonSlice = tail[tail.startIndex..<end.lowerBound]
        } else {
            jsonSlice = tail
        }
        let json = jsonSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8) else { return .malformed }

        if useNeeds {
            guard let p = try? JSONDecoder().decode(NeedsInputPayload.self, from: data) else {
                return .malformed
            }
            return .value(.needsInput(question: p.question, options: p.options ?? []))
        } else {
            guard let p = try? JSONDecoder().decode(DonePayload.self, from: data) else {
                return .malformed
            }
            return .value(.done(summary: p.summary))
        }
    }
}
