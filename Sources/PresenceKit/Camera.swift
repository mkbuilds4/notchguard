import AVFoundation
import CoreVideo
import Foundation

/// Front camera wrapper. The session is configured once and only *running* during a burst,
/// so the camera light is on for well under a second per check.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "presence.camera.frames")
    private let control = DispatchQueue(label: "presence.camera.control")
    private let lock = NSLock()
    private var onFrame: ((CVPixelBuffer) -> Void)?

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    init(preset: AVCaptureSession.Preset = .vga640x480) throws {
        super.init()
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            throw NSError(domain: "NotchGuard", code: 2, userInfo: [NSLocalizedDescriptionKey: "no camera"])
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "NotchGuard", code: 3, userInfo: [NSLocalizedDescriptionKey: "camera input rejected"])
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// Caps the frame rate; a lower rate saves camera and image-processing power. nil = the camera's default.
    func setFrameRate(_ fps: Double?) {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device, (try? device.lockForConfiguration()) != nil else { return }
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        if let fps, let r = ranges.first(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, r.minFrameRate)))
        } else {
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
        }
        device.unlockForConfiguration()
    }

    /// Continuous frames (enrollment preview).
    func start(_ handler: @escaping (CVPixelBuffer) -> Void) {
        lock.withLock { onFrame = handler }
        control.async { self.session.startRunning() }
    }

    func stop() {
        lock.withLock { onFrame = nil }
        control.sync { session.stopRunning() }
    }

    /// Run the camera just long enough for auto-exposure to settle, keep a few frames, stop.
    func burst(duration: TimeInterval = 1.2, skipFirst: TimeInterval = 0.6, keep: Int = 3) async -> [CVPixelBuffer] {
        await withCheckedContinuation { cont in
            // One slot per slice of the post-warmup window; holding only `keep` buffers
            // avoids starving the capture pool.
            var slots = [CVPixelBuffer?](repeating: nil, count: keep)
            var started: Date? // clock starts at the first frame: a cold camera takes a while to deliver one
            let slice = (duration - skipFirst) / Double(keep)
            var done = false
            let finish = { // always on `queue`
                guard !done else { return }
                done = true
                self.lock.withLock { self.onFrame = nil }
                self.control.async { self.session.stopRunning() }
                cont.resume(returning: slots.compactMap { $0 })
            }
            lock.withLock {
                onFrame = { pb in
                    if started == nil { started = Date() }
                    let t = Date().timeIntervalSince(started!)
                    if t >= skipFirst { slots[min(keep - 1, Int((t - skipFirst) / slice))] = pb }
                    if t >= duration { finish() }
                }
            }
            control.async { self.session.startRunning() }
            // Safety net if no frames arrive (camera busy, lid closed).
            queue.asyncAfter(deadline: .now() + duration + 3) { finish() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = lock.withLock { onFrame }
        handler?(pb)
    }
}
