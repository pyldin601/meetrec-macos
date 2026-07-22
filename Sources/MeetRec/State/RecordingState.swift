import Foundation

/// The start/stop recording state and its start timestamp.
///
/// `changes` is multicast: every access returns an independent stream that
/// yields the current status first, then every transition.
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

    func start(at date: Date = Date()) {
        guard status == .stopped else { return }
        transition(to: .started(at: date))
    }

    func stop() {
        guard status != .stopped else { return }
        transition(to: .stopped)
    }

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
