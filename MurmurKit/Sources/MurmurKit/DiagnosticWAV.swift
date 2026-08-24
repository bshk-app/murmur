import Foundation

enum DiagnosticWAV {
    static func data(samples: [Float]) -> Data {
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        var output = Data(capacity: 44 + Int(dataBytes))

        func append(_ string: String) {
            output.append(contentsOf: string.utf8)
        }
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        }
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        }

        append("RIFF")
        append(36 + dataBytes)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))       // PCM
        append(UInt16(1))       // mono
        append(UInt32(16_000))
        append(UInt32(32_000))  // sample rate × 2 bytes
        append(UInt16(2))
        append(UInt16(16))
        append("data")
        append(dataBytes)

        for sample in samples {
            let pcm = Int16(max(-32_767, min(32_767, (sample * 32_767).rounded())))
            withUnsafeBytes(of: pcm.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }

    static func write(samples: [Float], to url: URL) throws {
        try data(samples: samples).write(to: url, options: .atomic)
    }
}
