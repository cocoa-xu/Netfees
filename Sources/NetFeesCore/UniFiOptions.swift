import Foundation

public struct UniFiOptions: Codable, Equatable, Sendable {
    public let showsInMenuBar: Bool
    public let refreshInterval: Int

    public init(showsInMenuBar: Bool = false, refreshInterval: Int = 5) throws {
        guard (1...86_400).contains(refreshInterval) else { throw UniFiOptionsError.interval }
        self.showsInMenuBar = showsInMenuBar
        self.refreshInterval = refreshInterval
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(showsInMenuBar: values.decode(Bool.self, forKey: .showsInMenuBar),
                      refreshInterval: values.decode(Int.self, forKey: .refreshInterval))
    }
}

public enum UniFiOptionsError: Error, LocalizedError {
    case interval
    public var errorDescription: String? { "Enter a whole number of seconds from 1 to 86400." }
}
