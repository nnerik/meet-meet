import Foundation

@MainActor
public protocol CalendarRefreshScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () async -> Void)
    func cancel()
}

@MainActor
public final class TaskCalendarRefreshScheduler: CalendarRefreshScheduling {
    private var pending: Task<Void, Never>?

    public init() {}

    public func schedule(after delay: TimeInterval, action: @escaping @MainActor () async -> Void) {
        cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await action()
        }
    }

    public func cancel() { pending?.cancel(); pending = nil }
}
