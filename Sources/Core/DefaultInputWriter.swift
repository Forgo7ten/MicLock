import Foundation

/// One logical command. Does NOT claim to cancel writes already accepted by HAL.
/// Sampling, timer scheduling and UI events are coordinated by AudioMonitor.
struct DefaultInputWriter {
    enum Origin: Equatable {
        case trustedSelection
        case protection(RestoreReason)
    }

    struct Request {
        let id: UInt64
        let target: AudioInputDevice
        let sourceUID: String?
        let origin: Origin
        let fromName: String?
        let shouldNotify: Bool
        var retryAttempt = 0
    }

    enum Failure {
        case selectionRejected
        case selectionUnconfirmed(uid: String)
        case targetOffline
        case protectionRejected
        case protectionUnconfirmed

        var message: String {
            switch self {
            case .selectionRejected: return "Unable to set default input device"
            case .selectionUnconfirmed: return "Unable to confirm default input change"
            case .targetOffline: return "Target input device is no longer available"
            case .protectionRejected: return "Unable to set default input device; protection will keep retrying"
            case .protectionUnconfirmed: return "Unable to confirm default input change; protection is retrying"
            }
        }
    }

    private(set) var pending: Request?
    private(set) var failure: Failure?
    private var nextID: UInt64 = 0
    private static let retryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
        .seconds(8), .seconds(16), .seconds(32), .seconds(64)
    ]

    var retryState: ProtectionRetryState? {
        guard let pending, case .protection = pending.origin else { return nil }
        switch failure {
        case .protectionRejected: return .setterRejected
        case .protectionUnconfirmed: return .awaitingConfirmation
        default: return nil
        }
    }

    var retryDelay: Duration? {
        guard let pending else { return nil }
        if pending.origin == .trustedSelection { return .milliseconds(500) }
        return Self.retryDelays[min(pending.retryAttempt, Self.retryDelays.count - 1)]
    }

    mutating func begin(
        target: AudioInputDevice, source: AudioInputDevice?,
        origin: Origin, shouldNotify: Bool
    ) {
        nextID &+= 1
        failure = nil
        pending = Request(
            id: nextID, target: target,
            sourceUID: origin == .trustedSelection ? nil : source?.uid,
            origin: origin, fromName: source?.name, shouldNotify: shouldNotify
        )
    }

    mutating func cancel() {
        pending = nil
        if case .protectionRejected = failure { failure = nil }
        if case .protectionUnconfirmed = failure { failure = nil }
    }

    mutating func clearFailure() { failure = nil }

    mutating func targetDisappeared() {
        pending = nil
        failure = .targetOffline
    }

    /// Call ONLY after a successful fresh current read (including an explicit nil).
    mutating func observe(_ current: AudioInputDevice?) -> Request? {
        if case .selectionUnconfirmed(let uid) = failure, current?.uid == uid {
            failure = nil
        }
        guard let request = pending, current?.uid == request.target.uid else { return nil }
        pending = nil
        failure = nil
        return request
    }

    mutating func submitted(accepted: Bool, initial: Bool) {
        guard let pending else { return }
        if pending.origin == .trustedSelection {
            if !accepted && initial {
                self.pending = nil
                failure = .selectionRejected
            }
        } else if !accepted {
            failure = .protectionRejected
        } else if pending.retryAttempt >= 4 {
            failure = .protectionUnconfirmed
        } else {
            failure = nil
        }
    }

    /// nil means a trusted command expired, or no command remains.
    /// Protection retains the existing capped backoff; retries never touch Auto.
    mutating func prepareRetry() -> Request? {
        guard var request = pending else { return nil }
        if request.origin == .trustedSelection && request.retryAttempt >= 1 {
            pending = nil
            failure = .selectionUnconfirmed(uid: request.target.uid)
            return nil
        }
        request.retryAttempt = min(request.retryAttempt + 1, Self.retryDelays.count)
        pending = request
        return request
    }
}
