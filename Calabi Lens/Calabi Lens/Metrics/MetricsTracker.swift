import Foundation
import Combine

final class MetricsTracker: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var rttMs: Double = 0
    @Published private(set) var throughputBytesPerSec: Double = 0
    @Published private(set) var droppedFramesTotal: Int = 0
    @Published private(set) var droppedFramesLast60s: Int = 0
    @Published private(set) var queueDepth: Int = 0
    @Published private(set) var lastSendTime: Date?
    @Published private(set) var frameCounter: UInt64 = 0

    // MARK: - Internal State

    private var throughputBuckets: [TimeInterval: Int] = [:]
    private var dropTimestamps: [Date] = []
    private var frozen = false

    // MARK: - Record Send

    func recordSend(bytes: Int) {
        guard !frozen else { return }
        let now = Date()
        let bucketKey = floor(now.timeIntervalSince1970)

        throughputBuckets[bucketKey, default: 0] += bytes

        pruneDropTimestamps(now: now)
        let throughput = computeThroughput(now: now)

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.frozen else { return }
            self.frameCounter += 1
            self.lastSendTime = now
            self.throughputBytesPerSec = throughput
            self.droppedFramesLast60s = self.dropTimestamps.count
        }
    }

    // MARK: - Record Drop

    func recordDrop() {
        guard !frozen else { return }
        let now = Date()
        dropTimestamps.append(now)
        pruneDropTimestamps(now: now)

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.frozen else { return }
            self.droppedFramesTotal += 1
            self.droppedFramesLast60s = self.dropTimestamps.count
        }
    }

    // MARK: - Record RTT

    func recordRTT(_ ms: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.frozen else { return }
            self.rttMs = ms
        }
    }

    // MARK: - Update Queue Depth

    func updateQueueDepth(_ n: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.frozen else { return }
            self.queueDepth = n
        }
    }

    // MARK: - Reset For Session

    func resetForSession() {
        throughputBuckets.removeAll()
        dropTimestamps.removeAll()
        frozen = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rttMs = 0
            self.throughputBytesPerSec = 0
            self.droppedFramesTotal = 0
            self.droppedFramesLast60s = 0
            self.queueDepth = 0
            self.lastSendTime = nil
            self.frameCounter = 0
        }
    }

    // MARK: - Freeze Metrics

    func freezeMetrics() {
        frozen = true
    }

    // MARK: - Throughput Calculation

    private func computeThroughput(now: Date) -> Double {
        let currentSecond = floor(now.timeIntervalSince1970)
        let cutoff = currentSecond - 1

        // Prune buckets older than 2 seconds
        throughputBuckets = throughputBuckets.filter { $0.key >= currentSecond - 2 }

        // Sum buckets within the last 1 second
        var total = 0
        for (key, value) in throughputBuckets where key > cutoff {
            total += value
        }
        return Double(total)
    }

    // MARK: - Drop Timestamp Pruning

    private func pruneDropTimestamps(now: Date) {
        let cutoff = now.addingTimeInterval(-60)
        dropTimestamps.removeAll { $0 < cutoff }
    }
}
