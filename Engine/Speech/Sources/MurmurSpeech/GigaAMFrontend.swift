import MurmurCore
import Foundation
import Accelerate

/// GigaAM v3: 16 kHz, periodic Hann 320, hop 160, HTK mel, no normalization.
/// Returns channel-major log-mel. Padding belongs to the exported encoder contract.
enum GigaAMFrontend {
    static func features(_ samples: [Float]) throws -> (values: [Float], frames: Int) {
        let audio = samples.count < 320 ? samples + Array(repeating: 0, count: 320 - samples.count) : samples
        let frames = (audio.count - 320) / 160 + 1
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, 320, .FORWARD) else { throw CocoaError(.featureUnsupported) }
        defer { vDSP_DFT_DestroySetup(setup) }
        let window = (0..<320).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 320)) }
        let maxMel = 2595 * log10(1 + 8000.0 / 700)
        let points = (0..<66).map { 700 * (pow(10, maxMel * Double($0) / 65 / 2595) - 1) }
        var filters = [Float](repeating: 0, count: 161 * 64)
        for bin in 0..<161 {
            let hz = Double(bin) * 50
            for band in 0..<64 {
                filters[bin * 64 + band] = Float(max(0, min((hz - points[band]) / (points[band + 1] - points[band]),
                                                         (points[band + 2] - hz) / (points[band + 2] - points[band + 1]))))
            }
        }
        var spectrum = [Float](repeating: 0, count: frames * 161)
        var real = [Float](repeating: 0, count: 320)
        let zero = [Float](repeating: 0, count: 320)
        var outReal = zero, outImag = zero
        for frame in 0..<frames {
            for i in 0..<320 { real[i] = audio[frame * 160 + i] * window[i] }
            vDSP_DFT_Execute(setup, real, zero, &outReal, &outImag)
            for bin in 0..<161 { spectrum[frame * 161 + bin] = outReal[bin] * outReal[bin] + outImag[bin] * outImag[bin] }
        }
        var mel = [Float](repeating: 0, count: frames * 64)
        vDSP_mmul(spectrum, 1, filters, 1, &mel, 1, vDSP_Length(frames), 64, 161)
        var result = mel
        for band in 0..<64 {
            for frame in 0..<frames { result[band * frames + frame] = log(min(1e9, max(1e-9, mel[frame * 64 + band]))) }
        }
        return (result, frames)
    }
}
