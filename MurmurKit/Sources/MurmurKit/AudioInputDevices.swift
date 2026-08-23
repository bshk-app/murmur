@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// A current Core Audio input. Persist `uid`, never `audioID`: numeric device IDs
/// are process-local and may change when USB/Bluetooth hardware reconnects.
public struct MicrophoneDevice: Sendable, Equatable, Identifiable {
    let audioID: AudioDeviceID
    public let name: String
    public let uid: String
    public var id: String { uid }
}

/// Persisted microphone choice shared by both app pipelines.
public enum MicrophoneSetting {
    public static let defaultsKey = "murmur.microphoneUID"
    /// The empty value deliberately means "do not pin the engine" — Core Audio
    /// then follows the current system default at every recording.
    public static let systemDefaultUID = ""

    public static var currentUID: String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey) ?? systemDefaultUID
        return value.isEmpty ? nil : value
    }
}

/// Core Audio input discovery and routing.
public enum AudioInputDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var property = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return takeRetainedString(value)
    }

    /// Core Audio's string properties return caller-owned CFObjects.
    static func takeRetainedString(_ value: Unmanaged<CFString>) -> String {
        value.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var property = address(
            kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Inputs currently connected to the machine, in stable picker order.
    public static func available() -> [MicrophoneDevice] {
        sorted(allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0,
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return MicrophoneDevice(audioID: id, name: name, uid: uid)
        })
    }

    static func sorted(_ devices: [MicrophoneDevice]) -> [MicrophoneDevice] {
        devices.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
        }
    }

    /// The one definition of "which device does this persisted value mean": empty
    /// means System Default (nothing to pin), otherwise an exact UID match, and a
    /// device that has since disappeared means nothing.
    private static func device(
        for preferredUID: String?,
        in devices: [MicrophoneDevice]
    ) -> MicrophoneDevice? {
        guard let preferredUID, !preferredUID.isEmpty else { return nil }
        return devices.first { $0.uid == preferredUID }
    }

    /// A Picker selection must have a matching row. If a persisted device has
    /// disappeared, show and use System Default rather than an unlabeled value.
    public static func sanitizedUID(
        _ preferredUID: String,
        devices: [MicrophoneDevice]
    ) -> String {
        device(for: preferredUID, in: devices)?.uid ?? MicrophoneSetting.systemDefaultUID
    }

    /// Resolve by exact UID and apply its current AudioDeviceID. Returns false for
    /// System Default or a missing device; the caller then leaves AVAudioEngine
    /// unpinned so Core Audio selects its current default input.
    @discardableResult
    static func route(
        preferredUID: String?,
        devices: [MicrophoneDevice],
        apply: (AudioDeviceID) throws -> Void
    ) rethrows -> Bool {
        guard let match = device(for: preferredUID, in: devices) else { return false }
        try apply(match.audioID)
        return true
    }

    private static func routingError(code: Int, _ message: String) -> NSError {
        NSError(
            domain: "Murmur.AudioInputDevices",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Point the engine's input node at the preferred device. Must run before
    /// reading `outputFormat(forBus:)` or starting the engine.
    static func route(preferredUID: String?, on engine: AVAudioEngine) throws {
        try route(preferredUID: preferredUID, devices: available()) { id in
            guard let unit = engine.inputNode.audioUnit else {
                throw routingError(code: -1, "input node has no audio unit")
            }
            var device = id
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw routingError(
                    code: Int(status),
                    "could not select microphone (Core Audio error \(status))"
                )
            }
        }
    }
}
