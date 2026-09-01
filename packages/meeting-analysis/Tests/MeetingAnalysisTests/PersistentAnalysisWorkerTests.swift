import Foundation
import MeetingCore
import Testing
@testable import MeetingAnalysis

@Test func persistentWorkerCompletesAndRetriesJobs() async throws {
    let store = try MeetingStore(path: ":memory:")
    try store.save(Meeting(id: "m"))
    let worker = PersistentAnalysisWorker(store: store, retryPolicy: .init(maximumAttempts: 2, initialDelay: .seconds(1)))
    await worker.register(kind: "ok") { _ in }
    try store.enqueue(MeetingCore.AnalysisJob(id: "ok", meetingId: "m", kind: "ok", priority: 2, availableAt: .distantPast))
    #expect(try await worker.runOnce(now: Date(timeIntervalSince1970: 100)))
    #expect(try store.analysisJob(id: "ok")?.status == .completed)

    await worker.register(kind: "retry") { _ in throw TestFailure() }
    let now = Date(timeIntervalSince1970: 200)
    try store.enqueue(MeetingCore.AnalysisJob(id: "retry", meetingId: "m", kind: "retry", availableAt: .distantPast))
    #expect(try await worker.runOnce(now: now))
    let retriedJob = try store.analysisJob(id: "retry")
    let retried = try #require(retriedJob)
    #expect(retried.status == .pending)
    #expect(retried.retryCount == 1)
    #expect(retried.availableAt > now)
}

@Test func durableQueueClaimsByPriorityAndResumesInterruptedWork() throws {
    let store = try MeetingStore(path: ":memory:")
    try store.save(Meeting(id: "m"))
    try store.enqueue(MeetingCore.AnalysisJob(id: "low", meetingId: "m", kind: "x", priority: 0, availableAt: .distantPast))
    try store.enqueue(MeetingCore.AnalysisJob(id: "high", meetingId: "m", kind: "x", priority: 2, availableAt: .distantPast))
    #expect(try store.pendingAnalysisJobCount() == 2)
    #expect(try store.claimNextAnalysisJob()?.id == "high")
    #expect(try store.recoverInterruptedWork().recoveredJobCount == 1)
    #expect(try store.analysisJob(id: "high")?.status == .pending)
}

private struct TestFailure: Error {}
