import AVFoundation
import Foundation

/// Plane 3: Serialized Post-Processing Actor.
/// Coordinates lossless `AVMutableComposition` / `AVAssetExportSession` passthrough muxing
/// for split MP4/M4A tracks and pure-native streaming `.ts` -> `.mp4` remuxing via `NativeMP4Remuxer`.
public actor FFmpegMuxActor {
    public static let shared = FFmpegMuxActor()

    private init() {}

    public var isFFmpegFrameworkPresent: Bool {
        Bundle.main.privateFrameworksURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("FFmpeg.framework").path)
        } == true
    }

    /// Remuxes separate video and audio track files into a unified fast-start MP4 container without re-encoding.
    public func remux(videoURL: URL, audioURL: URL, destinationURL: URL) async throws {
        try? FileManager.default.removeItem(at: destinationURL)
        try await passthroughAVFoundationMux(videoURL: videoURL, audioURL: audioURL, destinationURL: destinationURL)
    }

    /// Losslessly remuxes a single MPEG-TS stream into a fast-start ISO-BMFF `.mp4` container
    /// via pure native `CoreMedia` + `AVAssetWriter` (`NativeMP4Remuxer`).
    public func remuxSingleStreamToMP4(sourceURL: URL, destinationURL: URL) async throws {
        try? FileManager.default.removeItem(at: destinationURL)
        if NativeMP4Remuxer.isISOBaseMediaFile(at: sourceURL) {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return
        }
        try await NativeMP4Remuxer.remuxMPEGTS(from: sourceURL, to: destinationURL)
    }

    private func passthroughAVFoundationMux(videoURL: URL, audioURL: URL, destinationURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let effectiveDuration: CMTime = {
            if videoDuration.isNumeric && audioDuration.isNumeric && videoDuration.seconds > 0 && audioDuration.seconds > 0 {
                return CMTimeMinimum(videoDuration, audioDuration)
            }
            return videoDuration
        }()

        if let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
           let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: effectiveDuration), of: srcVideo, at: .zero)
        }

        if let srcAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: effectiveDuration), of: srcAudio, at: .zero)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "Dysprosium.Mux", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create passthrough muxer"])
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: destinationURL, as: .mp4)
    }
}
