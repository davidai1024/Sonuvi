// Sonuvi — GPL-3.0. Keep macOS 27 screenshot OCR off its stalling revision-3 path.
import Foundation
import Vision
import CoreML

final class ScreenshotOCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [VNRequest] = []
    private var cancelled = false
    func register(_ request:VNRequest) throws {
        lock.lock();let stopped = cancelled
        if !stopped { requests.append(request) };lock.unlock()
        if stopped { request.cancel();throw CancellationError() }
    }
    func cancel() {
        lock.lock();cancelled = true;let pending = requests;lock.unlock()
        for request in pending { request.cancel() }
    }
}

enum ScreenshotVisionEngine {
    static var needsCPUWorkaround:Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }
    static func perform(image:CGImage,cpuOnly:Bool,cancellation:ScreenshotOCRCancellation) throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        // Revision 2 supports both Chinese and English. On macOS 27, revision 3
        // can still compile an ANE model even with an explicit CPU device.
        // Explicit CPU fixtures use the same revision across macOS runners.
        if cpuOnly || needsCPUWorkaround { request.revision = VNRecognizeTextRequestRevision2 }
        request.recognitionLevel = .accurate;request.recognitionLanguages = ["zh-Hans","zh-Hant","en-US"];request.usesLanguageCorrection = true
        if cpuOnly || needsCPUWorkaround {
            // usesCPUOnly is deprecated and can be ignored on newer systems.
            // Select the supported CPU device before Vision creates its detector.
            if #available(macOS 14.0,*),let devices = try? request.supportedComputeStageDevices {
                for (stage,available) in devices {
                    if let cpu = available.first(where: { if case .cpu = $0 {return true};return false }) { request.setComputeDevice(cpu,for:stage) }
                }
            } else { request.usesCPUOnly = true }
        }
        try cancellation.register(request)
        try VNImageRequestHandler(cgImage:image).perform([request])
        return request
    }
}
