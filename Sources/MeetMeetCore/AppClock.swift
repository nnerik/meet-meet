import Foundation

public protocol AppClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: AppClock {
    public init() {}
    public var now: Date { Date() }
}
