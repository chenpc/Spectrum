import Foundation
import AVFoundation
import os

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
        do {
            let duration = try await asset.load(.duration)
            result.duration = duration.seconds.isFinite ? duration.seconds : nil
        } catch {
            Log.video.warning("Failed to load duration for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Creation date
        do {
            if let creationDate = try await asset.load(.creationDate) {
                let dateValue = try await creationDate.load(.dateValue)
                result.creationDate = dateValue
            }
        } catch {
            Log.video.warning("Failed to load creation date for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Video track
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = videoTracks.first {
                do {
                    let size = try await videoTrack.load(.naturalSize)
                    let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                    let transformedSize = size.applying(transform)
                    result.pixelWidth = Int(abs(transformedSize.width))
                    result.pixelHeight = Int(abs(transformedSize.height))
                } catch {
                    Log.video.warning("Failed to load video size for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                do {
                    let descriptions = try await videoTrack.load(.formatDescriptions)
                    for desc in descriptions {
                        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                        result.videoCodec = fourCCToString(mediaSubType)
                        break
                    }
                } catch {
                    Log.video.warning("Failed to load video format for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Log.video.warning("Failed to load video tracks for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Audio track
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audioTrack = audioTracks.first {
                do {
                    let descriptions = try await audioTrack.load(.formatDescriptions)
                    for desc in descriptions {
                        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                        result.audioCodec = fourCCToString(mediaSubType)
                        break
                    }
                } catch {
                    Log.video.warning("Failed to load audio format for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Log.video.warning("Failed to load audio tracks for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // GPS metadata
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if let key = item.commonKey {
                    if key == .commonKeyLocation {
                        do {
                            if let value = try await item.load(.stringValue) {
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
                        } catch {
                            Log.video.warning("Failed to load GPS metadata value for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        } catch {
            Log.video.warning("Failed to load metadata for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
