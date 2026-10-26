import Accelerate
import CoreAudio
import Foundation

struct CaptureError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (OSStatus \(status))" }
}

/// Captures everything the Mac is playing via a Core Audio process tap (macOS 14.2+),
/// mixes it to mono and pushes it into a `SampleRing`.
final class SystemAudioCapture {
    let ring: SampleRing
    private(set) var sampleRate: Double = 48_000
    private(set) var deviceName = ""

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "audioviz.io", qos: .userInteractive)
    private var mono = [Float](repeating: 0, count: 8192) // only touched on ioQueue
    private var tapBufferCount = 1

    init(ring: SampleRing) {
        self.ring = ring
    }

    deinit { stop() }

    func start() throws {
        stop()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "AudioViz"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
        tapID = tap

        var format = AudioStreamBasicDescription()
        try getProperty(tapID, kAudioTapPropertyFormat, &format)
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        tapBufferCount = nonInterleaved ? max(Int(format.mChannelsPerFrame), 1) : 1

        var outputID = AudioObjectID(kAudioObjectUnknown)
        try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &outputID)
        let outputUID = try stringProperty(outputID, kAudioDevicePropertyDeviceUID)
        deviceName = (try? stringProperty(outputID, kAudioObjectPropertyName)) ?? "Output"

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioViz Tap",
            kAudioAggregateDeviceUIDKey: "com.antoniomindov.audioviz.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Create aggregate device")
        aggregateID = agg

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }, "Create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "Start capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Calls `handler` on the main queue whenever the default output device changes.
    func observeDefaultOutputChanges(_ handler: @escaping () -> Void) {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }

    // MARK: - IO

    private func process(_ list: UnsafePointer<AudioBufferList>) {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        // The tap's streams come after any input streams of the output sub-device.
        let buffers = all.suffix(tapBufferCount)
        var channels = 0
        var frames = 0
        for b in buffers where b.mData != nil {
            let ch = max(Int(b.mNumberChannels), 1)
            channels += ch
            frames = max(frames, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch))
        }
        guard frames > 0, channels > 0 else { return }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }

        mono.withUnsafeMutableBufferPointer { out in
            let m = out.baseAddress!
            vDSP_vclr(m, 1, vDSP_Length(frames))
            for b in buffers {
                guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = max(Int(b.mNumberChannels), 1)
                let n = min(frames, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch))
                for c in 0..<ch {
                    vDSP_vadd(data + c, vDSP_Stride(ch), m, 1, m, 1, vDSP_Length(n))
                }
            }
            var scale = 1 / Float(channels)
            vDSP_vsmul(m, 1, &scale, m, 1, vDSP_Length(frames))
            ring.write(m, count: frames)
        }
    }

    // MARK: - Property helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func getProperty<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) throws {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Read property \(selector)")
    }

    private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Read string property \(selector)")
        guard let value else { throw CaptureError(step: "Read string property \(selector)", status: -1) }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw CaptureError(step: step, status: status) }
    }
}
