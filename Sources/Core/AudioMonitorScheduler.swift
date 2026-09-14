import Foundation

/// AudioMonitor 的单调时钟 / 延迟调度抽象。
/// timer 必须在 `schedule` 返回前完成登记；这样测试时钟可以确定性推进多级 watchdog，
/// 不依赖新建 Task 何时获得执行机会。
@MainActor
protocol AudioMonitorScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol AudioMonitorScheduling: AnyObject {
    var now: ContinuousClock.Instant { get }

    @discardableResult
    func schedule(
        after delay: Duration,
        action: @escaping @MainActor () -> Void
    ) -> AudioMonitorScheduledTask
}

@MainActor
final class ContinuousAudioMonitorScheduler: AudioMonitorScheduling {
    private let clock = ContinuousClock()

    var now: ContinuousClock.Instant {
        clock.now
    }

    @discardableResult
    func schedule(
        after delay: Duration,
        action: @escaping @MainActor () -> Void
    ) -> AudioMonitorScheduledTask {
        let token = ContinuousScheduledTask()
        token.task = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return token
    }

    @MainActor
    private final class ContinuousScheduledTask: AudioMonitorScheduledTask {
        var task: Task<Void, Never>?

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}
