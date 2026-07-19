import Foundation

/// One point on the EQ magnitude-response curve used by the editor graph.
public struct ResponsePoint: Codable, Equatable, Sendable {
    public var frequencyHz: Double
    public var magnitudeDb: Double
    public init(frequencyHz: Double, magnitudeDb: Double) {
        self.frequencyHz = frequencyHz
        self.magnitudeDb = magnitudeDb
    }
}

public extension Array where Element == ResponsePoint {
    /// Largest magnitude in the curve (the peak the preamp must compensate).
    var peakDb: Double { map(\.magnitudeDb).max() ?? 0 }
    var minDb: Double { map(\.magnitudeDb).min() ?? 0 }
}
