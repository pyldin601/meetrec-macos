extension AsyncStream {
    /// Maps each element to a new inner stream, switching to it and
    /// cancelling whatever inner iteration was running before — matching
    /// RxJS's `switchMap` / swift-async-algorithms' `flatMapLatest`.
    ///
    /// `@MainActor` isolated so the `Task`s it creates inherit main-actor
    /// isolation from this declaration (not from wherever `flatMapLatest` is
    /// called) — unlike a generic actor-agnostic combinator, this is safe to
    /// use with `@MainActor`-confined stores. Specialized to `AsyncStream`
    /// (rather than generic `AsyncSequence`) since that's all this app's
    /// stores produce, and it keeps this off `AsyncSequence.Failure`, which
    /// needs macOS 15.
    @MainActor
    func flatMapLatest<Inner>(_ transform: @escaping (Element) -> AsyncStream<Inner>) -> AsyncStream<Inner> {
        AsyncStream<Inner> { continuation in
            let outerTask = Task {
                var innerTask: Task<Void, Never>?
                for await element in self {
                    innerTask?.cancel()
                    innerTask = Task {
                        for await value in transform(element) {
                            continuation.yield(value)
                        }
                    }
                }
                innerTask?.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in outerTask.cancel() }
        }
    }
}
