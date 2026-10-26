import os

/// Lock-protected mono sample ring buffer: the audio IO thread writes, the render loop reads the latest window.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var total: UInt64 = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int = 1 << 17) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    func write(_ src: UnsafePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        var remaining = min(count, capacity)
        var s = src + (count - remaining)
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            (buffer + writeIndex).update(from: s, count: chunk)
            writeIndex = (writeIndex + chunk) % capacity
            s += chunk
            remaining -= chunk
        }
        total &+= UInt64(count)
    }

    /// Copies the most recent `count` samples (oldest first) and returns the total number of samples ever written.
    @discardableResult
    func readLatest(into dst: UnsafeMutablePointer<Float>, count: Int) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let n = min(count, capacity)
        var start = (writeIndex - n + capacity) % capacity
        var d = dst
        var remaining = n
        while remaining > 0 {
            let chunk = min(remaining, capacity - start)
            d.update(from: buffer + start, count: chunk)
            start = (start + chunk) % capacity
            d += chunk
            remaining -= chunk
        }
        return total
    }
}
