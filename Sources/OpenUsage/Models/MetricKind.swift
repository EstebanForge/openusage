import Foundation

/// How a metric's number is formatted. Mirrors OpenUsage's `format.kind`.
enum MetricKind: Hashable, Sendable {
    case percent      // used is 0...100
    case dollars      // used is an amount in USD
    case count        // used is an absolute count (with an optional suffix)
}
