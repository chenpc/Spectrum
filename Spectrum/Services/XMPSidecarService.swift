import Foundation

enum XMPSidecarService {

    // MARK: - Public API

    /// Sidecar path: {name}.{ext}.xmp — preserves original extension to distinguish photo vs video.
    static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("xmp")
    }

    /// Write XMP sidecar. Caller must ensure security scope is active.
    static func write(edit: CompositeEdit, originalOrientation: Int,
                      gyroConfig: String? = nil, for imageURL: URL) throws {
        let (exifR, exifH) = exifOrientationToTransform(originalOrientation)
        let editR = edit.rotation
        let editH = edit.flipH

        // Compose EXIF original transform with edit transform
        let combinedR: Int
        let combinedH: Bool
        if !editH {
            combinedR = (exifR + editR) % 360
            combinedH = exifH
        } else {
            combinedR = (editR - exifR + 360) % 360
            combinedH = !exifH
        }
        let ori = transformToExifOrientation(rotation: combinedR, flipH: combinedH)

        let hasCrop = edit.crop != nil
        let cropTop    = edit.crop?.y ?? 0
        let cropLeft   = edit.crop?.x ?? 0
        let cropBottom = hasCrop ? edit.crop!.y + edit.crop!.height : 1
        let cropRight  = hasCrop ? edit.crop!.x + edit.crop!.width : 1

        // Escape gyroConfig JSON for XML attribute
        let gyroAttr = gyroConfig.map { escapeXMLAttribute($0) }

        var xml = """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Spectrum 1.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:spectrum="http://spectrum.app/ns/1.0/"
            tiff:Orientation="\(ori)"
            crs:HasCrop="\(hasCrop ? "True" : "False")"
            crs:CropTop="\(formatDouble(cropTop))"
            crs:CropLeft="\(formatDouble(cropLeft))"
            crs:CropBottom="\(formatDouble(cropBottom))"
            crs:CropRight="\(formatDouble(cropRight))"
            crs:CropAngle="0"
        """
        if let g = gyroAttr {
            xml += "\n        spectrum:GyroConfig=\"\(g)\""
        }
        xml += """
        />
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let url = sidecarURL(for: imageURL)
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    struct SidecarData {
        var rotation: Int = 0
        var flipH: Bool = false
        var crop: CropRect? = nil
        var gyroConfig: String? = nil
    }

    /// Read XMP sidecar → SidecarData. Returns nil if no sidecar found.
    static func read(for imageURL: URL, originalOrientation: Int) -> SidecarData? {
        let url = findSidecar(for: imageURL)
        guard let url else { return nil }

        guard let data = try? Data(contentsOf: url),
              let doc = try? XMLDocument(data: data) else { return nil }

        guard let desc = findDescription(in: doc) else { return nil }

        // Read tiff:Orientation
        let xmpOri = intAttribute("tiff:Orientation", in: desc) ?? 1
        let (xmpR, xmpH) = exifOrientationToTransform(xmpOri)
        let (exifR, exifH) = exifOrientationToTransform(originalOrientation)

        // Reverse-compose to get edit transform
        let editH: Bool
        let editR: Int
        if xmpH == exifH {
            editH = false
            editR = (xmpR - exifR + 360) % 360
        } else {
            editH = true
            editR = (xmpR + exifR) % 360
        }

        // Read crs:HasCrop
        let hasCrop = stringAttribute("crs:HasCrop", in: desc)?.lowercased() == "true"
        var crop: CropRect? = nil
        if hasCrop,
           let top = doubleAttribute("crs:CropTop", in: desc),
           let left = doubleAttribute("crs:CropLeft", in: desc),
           let bottom = doubleAttribute("crs:CropBottom", in: desc),
           let right = doubleAttribute("crs:CropRight", in: desc) {
            let w = right - left
            let h = bottom - top
            if w > 0, h > 0 {
                crop = CropRect(x: left, y: top, width: w, height: h)
            }
        }

        // Read spectrum:GyroConfig
        let gyroConfig = stringAttribute("spectrum:GyroConfig", in: desc)

        // Only return if there's actually something
        if editR == 0 && !editH && crop == nil && gyroConfig == nil { return nil }

        return SidecarData(rotation: editR, flipH: editH, crop: crop, gyroConfig: gyroConfig)
    }

    /// Delete sidecar file if it exists.
    static func deleteSidecar(for imageURL: URL) {
        try? FileManager.default.removeItem(at: sidecarURL(for: imageURL))
    }

    // MARK: - Private helpers

    private static func findSidecar(for imageURL: URL) -> URL? {
        let url = sidecarURL(for: imageURL)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Find <rdf:Description> element in the XMLDocument.
    private static func findDescription(in doc: XMLDocument) -> XMLElement? {
        // Try XPath with namespace
        if let nodes = try? doc.nodes(forXPath: "//*[local-name()='Description']"),
           let elem = nodes.first as? XMLElement {
            return elem
        }
        return nil
    }

    private static func stringAttribute(_ name: String, in element: XMLElement) -> String? {
        // Try direct attribute name (e.g. "tiff:Orientation")
        if let attr = element.attribute(forName: name) {
            return attr.stringValue
        }
        // Try local name only (for documents that use different prefixes)
        let localName = name.contains(":") ? String(name.split(separator: ":").last!) : name
        for attr in element.attributes ?? [] {
            if let attrName = attr.name, attrName.hasSuffix(localName) {
                return attr.stringValue
            }
        }
        return nil
    }

    private static func intAttribute(_ name: String, in element: XMLElement) -> Int? {
        guard let str = stringAttribute(name, in: element) else { return nil }
        return Int(str)
    }

    private static func doubleAttribute(_ name: String, in element: XMLElement) -> Double? {
        guard let str = stringAttribute(name, in: element) else { return nil }
        return Double(str)
    }

    private static func escapeXMLAttribute(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func formatDouble(_ value: Double) -> String {
        // Remove trailing zeros: "0.5" not "0.500000"
        let s = String(format: "%.6f", value)
        // Trim trailing zeros after decimal point
        if s.contains(".") {
            var trimmed = s
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }
        return s
    }

    // MARK: - Orientation conversion (full D4 group: 8 states)

    /// Convert EXIF orientation tag (1-8) to (rotation, flipH).
    /// Convention: flip first, then rotate.
    private static func exifOrientationToTransform(_ ori: Int) -> (rotation: Int, flipH: Bool) {
        switch ori {
        case 1: return (0, false)
        case 2: return (0, true)
        case 3: return (180, false)
        case 4: return (180, true)
        case 5: return (90, true)
        case 6: return (90, false)
        case 7: return (270, true)
        case 8: return (270, false)
        default: return (0, false)
        }
    }

    /// Convert (rotation, flipH) to EXIF orientation tag (1-8).
    private static func transformToExifOrientation(rotation: Int, flipH: Bool) -> Int {
        let r = (rotation % 360 + 360) % 360
        switch (r, flipH) {
        case (0, false):   return 1
        case (0, true):    return 2
        case (180, false): return 3
        case (180, true):  return 4
        case (90, true):   return 5
        case (90, false):  return 6
        case (270, true):  return 7
        case (270, false): return 8
        default:           return 1
        }
    }
}
