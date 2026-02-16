import Foundation
import AVFoundation

struct VideoMetadata {
    var duration: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var videoCodec: String?
    var audioCodec: String?
    var creationDate: Date?
    var latitude: Double?
    var longitude: Double?
}

enum VideoMetadataService {
    static func readMetadata(from url: URL) async -> VideoMetadata {
        var result = VideoMetadata()

        let asset = AVURLAsset(url: url)

        // Duration
        if let duration = try? await asset.load(.duration) {
            result.duration = duration.seconds.isFinite ? duration.seconds : nil
        }

        // Creation date
        if let creationDate = try? await asset.load(.creationDate),
           let dateValue = try? await creationDate.load(.dateValue) {
            result.creationDate = dateValue
        }

        // Video track
        if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
           let videoTrack = videoTracks.first {
            if let size = try? await videoTrack.load(.naturalSize) {
                let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                let transformedSize = size.applying(transform)
                result.pixelWidth = Int(abs(transformedSize.width))
                result.pixelHeight = Int(abs(transformedSize.height))
            }
            if let descriptions = try? await videoTrack.load(.formatDescriptions) {
                for desc in descriptions {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                    result.videoCodec = fourCCToString(mediaSubType)
                    break
                }
            }
        }

        // Audio track
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           let audioTrack = audioTracks.first {
            if let descriptions = try? await audioTrack.load(.formatDescriptions) {
                for desc in descriptions {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                    result.audioCodec = fourCCToString(mediaSubType)
                    break
                }
            }
        }

        // GPS metadata
        for item in (try? await asset.load(.metadata)) ?? [] {
            if let key = item.commonKey {
                if key == .commonKeyLocation, let value = try? await item.load(.stringValue) {
                    let parts = value.components(separatedBy: "+").filter { !$0.isEmpty }
                    if parts.count >= 2 {
                        // Format is typically "+lat+lon" or "+lat-lon"
                        let cleaned = value.replacingOccurrences(of: "/", with: "")
                        let scanner = Scanner(string: cleaned)
                        if let lat = scanner.scanDouble(), let lon = scanner.scanDouble() {
                            result.latitude = lat
                            result.longitude = lon
                        }
                    }
                }
            }
        }

        return result
    }

    private static func fourCCToString(_ code: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar(truncatingIfNeeded: (code >> 24) & 0xFF),
            CChar(truncatingIfNeeded: (code >> 16) & 0xFF),
            CChar(truncatingIfNeeded: (code >> 8) & 0xFF),
            CChar(truncatingIfNeeded: code & 0xFF),
            0
        ]
        return String(cString: bytes).trimmingCharacters(in: .whitespaces)
    }
}
