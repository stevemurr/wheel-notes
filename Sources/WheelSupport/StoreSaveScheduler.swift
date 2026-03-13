import Foundation

@MainActor
public final class StoreSaveScheduler {
    private let delay: Duration
    private var pendingTask: Task<Void, Never>?

    public init(delay: Duration) {
        self.delay = delay
    }

    deinit {
        pendingTask?.cancel()
    }

    public func schedule(_ operation: @escaping @MainActor () -> Void) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            operation()
        }
    }

    public func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    public func flush(_ operation: @escaping @MainActor () -> Void) {
        cancel()
        operation()
    }
}
