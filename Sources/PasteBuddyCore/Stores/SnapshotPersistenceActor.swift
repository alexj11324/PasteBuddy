import Foundation

struct PersistenceCommitLease: Sendable, Equatable {
    fileprivate let id: UUID
    let generation: UInt64
}

enum PersistenceCommitOutcome: Sendable {
    case abortedBeforeWrite
    case committed
    case failedAfterWrite
}

final class PersistenceCommitGate: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<PersistenceCommitLease?, Never>
    }

    private let lock = NSLock()
    private var activeLease: PersistenceCommitLease?
    private var supersessionBarrierGeneration: UInt64 = 0
    private var waiters: [Waiter] = []
    private var registeredWaiterIDs: Set<UUID> = []
    private var cancelledWaiterIDs: Set<UUID> = []

    func acquire(generation: UInt64) async -> PersistenceCommitLease? {
        let waiterID = UUID()
        _ = lock.withLock {
            registeredWaiterIDs.insert(waiterID)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueOrAcquire(
                    waiterID: waiterID,
                    generation: generation,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }
    }

    func tryAcquireImmediately(generation: UInt64) -> PersistenceCommitLease? {
        lock.withLock {
            guard generation > supersessionBarrierGeneration,
                  activeLease == nil else {
                return nil
            }
            let lease = PersistenceCommitLease(id: UUID(), generation: generation)
            activeLease = lease
            return lease
        }
    }

    func release(_ lease: PersistenceCommitLease, outcome: PersistenceCommitOutcome) {
        var resumptions: [(CheckedContinuation<PersistenceCommitLease?, Never>, PersistenceCommitLease?)] = []
        lock.lock()
        guard activeLease == lease else {
            lock.unlock()
            return
        }
        switch outcome {
        case .abortedBeforeWrite:
            break
        case .committed, .failedAfterWrite:
            supersessionBarrierGeneration = max(
                supersessionBarrierGeneration,
                lease.generation
            )
        }
        activeLease = nil

        var remainingWaiters: [Waiter] = []
        for waiter in waiters {
            if waiter.generation <= supersessionBarrierGeneration {
                resumptions.append((waiter.continuation, nil))
            } else {
                remainingWaiters.append(waiter)
            }
        }
        waiters = remainingWaiters

        if let nextIndex = waiters.indices.max(
            by: { waiters[$0].generation < waiters[$1].generation }
        ) {
            let next = waiters.remove(at: nextIndex)
            let nextLease = PersistenceCommitLease(id: next.id, generation: next.generation)
            activeLease = nextLease
            resumptions.append((next.continuation, nextLease))
        }
        lock.unlock()

        for (continuation, result) in resumptions {
            continuation.resume(returning: result)
        }
    }

    private func enqueueOrAcquire(
        waiterID: UUID,
        generation: UInt64,
        continuation: CheckedContinuation<PersistenceCommitLease?, Never>
    ) {
        var immediateResult: PersistenceCommitLease??
        lock.lock()
        registeredWaiterIDs.remove(waiterID)
        if cancelledWaiterIDs.remove(waiterID) != nil {
            immediateResult = .some(nil)
        } else if generation <= supersessionBarrierGeneration {
            immediateResult = .some(nil)
        } else if activeLease == nil {
            let lease = PersistenceCommitLease(id: waiterID, generation: generation)
            activeLease = lease
            immediateResult = .some(lease)
        } else {
            waiters.append(
                Waiter(
                    id: waiterID,
                    generation: generation,
                    continuation: continuation
                )
            )
        }
        lock.unlock()

        if let immediateResult {
            continuation.resume(returning: immediateResult)
        }
    }

    private func cancelWaiter(id: UUID) {
        var continuation: CheckedContinuation<PersistenceCommitLease?, Never>?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            continuation = waiters.remove(at: index).continuation
        } else if registeredWaiterIDs.contains(id) {
            cancelledWaiterIDs.insert(id)
        }
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}
