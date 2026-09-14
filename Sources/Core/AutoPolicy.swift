import Foundation

/// Mutually exclusive policy phases. No notification metadata or writer state.
struct AutoPolicy {
    struct Candidate {
        let revision: UInt64
        let preferredUID: String
        let preferredName: String
        let target: AudioInputDevice
        // nil means observed evidence exists, but its valid sampling window
        // was interrupted. Recovery must start a NEW complete interval.
        var validSince: ContinuousClock.Instant?
    }

    enum Phase {
        case stable
        case protecting(since: ContinuousClock.Instant)
        case considering(Candidate)
    }

    private(set) var phase: Phase = .stable

    mutating func reset() { phase = .stable }

    mutating func protect(at now: ContinuousClock.Instant) {
        phase = .protecting(since: now)
    }

    mutating func isProtecting(at now: ContinuousClock.Instant, interval: Duration) -> Bool {
        guard case .protecting(let since) = phase else { return false }
        if now < since.advanced(by: interval) { return true }
        phase = .stable
        return false
    }

    mutating func cancelCandidate() {
        if case .considering = phase { phase = .stable }
    }

    mutating func observedRevision(_ revision: UInt64) {
        if case .considering(let candidate) = phase,
           candidate.revision != revision {
            phase = .stable
        }
    }

    mutating func interruptSampling() {
        guard case .considering(var candidate) = phase else { return }
        candidate.validSince = nil
        phase = .considering(candidate)
    }

    /// The caller must provide a genuinely changed observation with no active
    /// command owning it. A mismatch with preferred ALONE never calls this.
    mutating func beginCandidate(
        target: AudioInputDevice, preferred: AudioInputDevice,
        revision: UInt64, validAt now: ContinuousClock.Instant?
    ) {
        phase = .considering(Candidate(
            revision: revision, preferredUID: preferred.uid,
            preferredName: preferred.name, target: target, validSince: now
        ))
    }

    mutating func resumeCandidate(at now: ContinuousClock.Instant) {
        guard case .considering(var candidate) = phase,
              candidate.validSince == nil else { return }
        candidate.validSince = now
        phase = .considering(candidate)
    }

    var candidate: Candidate? {
        guard case .considering(let candidate) = phase else { return nil }
        return candidate
    }

    func candidateDeadline(interval: Duration) -> ContinuousClock.Instant? {
        candidate?.validSince?.advanced(by: interval)
    }
}
