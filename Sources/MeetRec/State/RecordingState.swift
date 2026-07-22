import Foundation

/// Source of truth for whether a recording is running and since when. Not
/// wired into the app yet — groundwork for moving state propagation onto
/// async iterators.
///
/// `changes` is multicast: every access returns an independent stream that
/// yields the current status immediately (a late subscriber never misses the
/// standing state), then every transition. Transitions are never dropped —
/// buffering is unbounded, and elements are tiny and rare.
@MainActor
final class RecordingState {
    enum Status: Equatable {
        case stopped
        case started(at: Date)

        var startedAt: Date? {
            if case .started(let date) = self { return date }
            return nil
        }
    }

    private(set) var status: Status = .stopped
    private var subscribers: [UUID: AsyncStream<Status>.Continuation] = [:]

    var isStarted: Bool { status != .stopped }
    var startedAt: Date? { status.startedAt }

    /// No-op when already started — the original start date is kept.
    func start(at date: Date = Date()) {
        guard !isStarted else { return }
        transition(to: .started(at: date))
    }

    /// No-op when already stopped.
    func stop() {
        guard isStarted else { return }
        transition(to: .stopped)
    }

    /// The current status, then every subsequent change.
    var changes: AsyncStream<Status> {
        let (stream, continuation) = AsyncStream.makeStream(of: Status.self)
        let id = UUID()
        continuation.yield(status)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func transition(to new: Status) {
        status = new
        for subscriber in subscribers.values {
            subscriber.yield(new)
        }
    }
}
