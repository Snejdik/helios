import CoreAudio
import Foundation

struct AudioDeviceMetrics: Sendable, Identifiable, Equatable {
    let objectID: UInt32
    let name: String
    let uid: String?
    let hasInput: Bool
    let hasOutput: Bool
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRateHz: Double?
    let transportType: UInt32?

    var id: UInt32 { objectID }
}

struct AudioMetrics: Sendable, Equatable {
    let devices: [AudioDeviceMetrics]
    let defaultInputDeviceID: UInt32?
    let defaultOutputDeviceID: UInt32?
    let defaultSystemOutputDeviceID: UInt32?
    let inputTelemetrySuppressedForPrivacy: Bool

    var defaultInput: AudioDeviceMetrics? { defaultInputDeviceID.flatMap { id in devices.first { $0.objectID == id } } }
    var defaultOutput: AudioDeviceMetrics? { defaultOutputDeviceID.flatMap { id in devices.first { $0.objectID == id } } }
    var defaultSystemOutput: AudioDeviceMetrics? { defaultSystemOutputDeviceID.flatMap { id in devices.first { $0.objectID == id } } }
}

actor AudioProvider {
    func reset() {}
    func sample() -> MetricSample<AudioMetrics> { MetricSample(captureMetric { try Self.read() }) }

    static func read() throws -> AudioMetrics {
        let ids = try allDeviceIDs()
        let devices = ids.compactMap { device(id: $0) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return AudioMetrics(
            devices: devices,
            // Querying CoreAudio input-scope properties under the hardened runtime
            // requires microphone access. Helios does not record audio and should
            // not request microphone permission merely to inventory devices, so
            // input-side telemetry is intentionally left unprobed.
            defaultInputDeviceID: nil,
            defaultOutputDeviceID: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
            defaultSystemOutputDeviceID: defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice),
            inputTelemetrySuppressedForPrivacy: true
        )
    }

    private static func allDeviceIDs() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            throw TelemetryError.unavailable("CoreAudio device enumeration unavailable")
        }
        guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0, size <= 1_048_576 else {
            throw TelemetryError.invalidData("Invalid CoreAudio device list size")
        }
        if size == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else { throw TelemetryError.unavailable("CoreAudio device enumeration failed (\(status))") }
        return ids.filter { $0 != kAudioObjectUnknown }
    }

    private static func device(id: AudioObjectID) -> AudioDeviceMetrics? {
        guard let name = string(id, selector: kAudioObjectPropertyName), !name.isEmpty else { return nil }
        return AudioDeviceMetrics(
            objectID: id,
            name: name,
            uid: string(id, selector: kAudioDevicePropertyDeviceUID),
            // Input-side values are deliberately represented as unavailable by
            // AudioMetrics.inputTelemetrySuppressedForPrivacy and never displayed
            // as authoritative values. Avoiding input scope keeps Helios out of
            // the microphone permission surface.
            hasInput: false,
            hasOutput: hasStreams(id, scope: kAudioDevicePropertyScopeOutput),
            inputChannels: 0,
            outputChannels: channelCount(id, scope: kAudioDevicePropertyScopeOutput),
            nominalSampleRateHz: double(id, selector: kAudioDevicePropertyNominalSampleRate),
            transportType: uint32(id, selector: kAudioDevicePropertyTransportType)
        )
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> UInt32? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size), size <= 1_048_576 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { partial, buffer in
            let channels = Int(buffer.mNumberChannels)
            let (sum, overflow) = partial.addingReportingOverflow(channels)
            return overflow ? Int.max : sum
        }
    }

    private static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    private static func double(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              value.isFinite, value > 0, value < 10_000_000 else { return nil }
        return value
    }

    private static func uint32(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
