import Foundation

/// `work`'s answer, or nil when it takes longer than `timeout` (the work
/// goes on).
@MainActor
func withinTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
    let once = ResumeOnceBox<T>()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        Task { @MainActor in once.resume(continuation, with: await work()) }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            once.resume(continuation, with: nil)
        }
    }
}

/// Waits for `task` to finish, at most `timeout` (the task goes on).
@MainActor
func waitForTask(_ task: Task<Void, Never>, upTo timeout: Duration) async {
    _ = await withinTimeout(timeout) { await task.value }
}

/// Resumes a continuation once, whichever answer comes first.
@MainActor
private final class ResumeOnceBox<T: Sendable> {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<T?, Never>, with value: T?) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
