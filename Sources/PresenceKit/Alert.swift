import CoreImage
import CoreVideo
import Foundation

/// Intruder evidence: saves frames to ~/Pictures/Presence Lock and texts them over iMessage.
enum Alert {
    static let folder: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Presence Lock")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func save(_ frames: [CVPixelBuffer]) -> [URL] {
        let ci = CIContext()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = stamp.string(from: Date())
        return frames.enumerated().compactMap { i, pb in
            let url = folder.appendingPathComponent("\(base) \(i + 1).jpg")
            guard let data = ci.jpegRepresentation(of: CIImage(cvPixelBuffer: pb), colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
            else { return nil }
            return (try? data.write(to: url)) != nil ? url : nil
        }
    }

    /// Sends through the Messages app (first run asks to let Presence Lock control Messages).
    static func send(to recipient: String, text: String, photos: [URL]) {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let sends = ([("send \(q(text)) to buddyRef")] + photos.map { "send (POSIX file \(q($0.path))) to buddyRef" })
            .joined(separator: "\n  delay 1\n  ")
        let script = """
        tell application "Messages"
          set svc to 1st account whose service type = iMessage
          set buddyRef to participant \(q(recipient)) of svc
          \(sends)
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        p.terminationHandler = { proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log(proc.terminationStatus == 0 ? "alert sent to \(recipient) with \(photos.count) photo(s)"
                                            : "alert failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        do { try p.run() } catch { log("alert failed: \(error.localizedDescription)") }
    }
}
