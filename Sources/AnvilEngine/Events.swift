import Foundation

/// Token / cost / rate-limit telemetry surfaced from the stream.
public struct Usage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalCostUSD: Double?
    public var rateLimit: RateLimitInfo?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalCostUSD: Double? = nil,
        rateLimit: RateLimitInfo? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalCostUSD = totalCostUSD
        self.rateLimit = rateLimit
    }
}

/// Subscription rate-limit window reported by `rate_limit_event`. `resetsAt` is kept as a
/// raw epoch value because the CLI's encoding (seconds vs. ms) is not contractually fixed.
public struct RateLimitInfo: Sendable, Equatable, Decodable {
    public var rateLimitType: String?
    public var status: String?
    public var overageStatus: String?
    public var isUsingOverage: Bool?
    public var resetsAt: Double?

    public init(
        rateLimitType: String? = nil,
        status: String? = nil,
        overageStatus: String? = nil,
        isUsingOverage: Bool? = nil,
        resetsAt: Double? = nil
    ) {
        self.rateLimitType = rateLimitType
        self.status = status
        self.overageStatus = overageStatus
        self.isUsingOverage = isUsingOverage
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case rateLimitType, status, overageStatus, isUsingOverage, resetsAt
    }

    // Lenient: tolerate missing fields and a string-or-number resetsAt so an unexpected
    // shape never drops the whole event.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rateLimitType = (try? c.decodeIfPresent(String.self, forKey: .rateLimitType)) ?? nil
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        overageStatus = (try? c.decodeIfPresent(String.self, forKey: .overageStatus)) ?? nil
        isUsingOverage = (try? c.decodeIfPresent(Bool.self, forKey: .isUsingOverage)) ?? nil
        if let d = (try? c.decodeIfPresent(Double.self, forKey: .resetsAt)) ?? nil {
            resetsAt = d
        } else if let s = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil {
            resetsAt = Double(s)
        } else {
            resetsAt = nil
        }
    }
}

/// Events emitted by a run, derived from the `stream-json` event stream.
public enum AnvilEvent: Sendable {
    case started(sessionID: String, model: String, cwd: String)
    case output(String)
    case usage(Usage)
    case needsInput(question: String, options: [String])
    case done(summary: String?)
    case failed(EngineError)
}

/// Lifecycle of a run. `needsInput` ends the turn but not the run — `resume` drives it back
/// to `running`. `done`/`failed`/`canceled` are terminal.
public enum RunState: Sendable, Equatable {
    case queued
    case running
    case needsInput(question: String, options: [String])
    case done(summary: String?)
    case failed(String)
    case canceled
}
