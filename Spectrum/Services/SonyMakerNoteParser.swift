import Foundation

enum SonyMakerNoteParser {

    /// Extract the raw PictureProfile byte value from Sony MakerNote tag 0x9416.
    /// Returns the raw integer (e.g. 28=S-Log2, 31=S-Log3, 32=HLG1, 35=HLG, 45=HLG Still).
    static func extractPictureProfileRawValue(from url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Find "Exif\0\0" marker followed by valid TIFF header.
        // HEIF files may have multiple "Exif\0\0" occurrences (e.g. in item info boxes);
        // only the one followed by "II*\0" or "MM\0*" is the real Exif data.
        let exifPattern: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        var tiffBase = 0
        var littleEndian = true
        var found = false

        var searchFrom = 0
        while let marker = findBytes(data, target: exifPattern, from: searchFrom) {
            let candidate = marker + 6
            guard candidate + 8 <= data.count else { break }

            let b0 = data[candidate], b1 = data[candidate + 1]
            if (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) {
                let le = (b0 == 0x49)
                let magic = readUInt16(data, at: candidate + 2, littleEndian: le)
                if magic == 42 {
                    tiffBase = candidate
                    littleEndian = le
                    found = true
                    break
                }
            }
            searchFrom = marker + 1
        }
        guard found else { return nil }

        // IFD0 offset
        let ifd0Offset = Int(readUInt32(data, at: tiffBase + 4, littleEndian: littleEndian))

        // Find ExifIFD pointer (tag 0x8769) in IFD0
        guard let exifIFDEntry = findTagInIFD(data: data, tiffBase: tiffBase, ifdOffset: ifd0Offset, tag: 0x8769, littleEndian: littleEndian) else { return nil }
        let exifIFDOffset = Int(readUInt32(data, at: exifIFDEntry.valueOffset, littleEndian: littleEndian))

        // Find MakerNote (tag 0x927C) in ExifIFD
        guard let makerNoteEntry = findTagInIFD(data: data, tiffBase: tiffBase, ifdOffset: exifIFDOffset, tag: 0x927C, littleEndian: littleEndian) else { return nil }

        let makerNoteAbs: Int
        if makerNoteEntry.count > 4 {
            makerNoteAbs = tiffBase + Int(readUInt32(data, at: makerNoteEntry.valueOffset, littleEndian: littleEndian))
        } else {
            makerNoteAbs = makerNoteEntry.valueOffset
        }

        // Verify "SONY DSC \0\0\0" header (12 bytes)
        let sonyHeader: [UInt8] = [0x53, 0x4F, 0x4E, 0x59, 0x20, 0x44, 0x53, 0x43, 0x20, 0x00, 0x00, 0x00]
        guard makerNoteAbs + 12 <= data.count else { return nil }
        for i in 0..<12 {
            guard data[makerNoteAbs + i] == sonyHeader[i] else { return nil }
        }

        // Parse Sony IFD starting at makerNote + 12
        let sonyIFDStart = makerNoteAbs + 12
        guard let tag9416 = findTagInIFD(data: data, tiffBase: tiffBase, ifdOffset: sonyIFDStart - tiffBase, tag: 0x9416, littleEndian: littleEndian) else { return nil }

        // tag 0x9416 is type UNDEFINED (7), the value offset points to encrypted data block
        let encryptedOffset: Int
        if tag9416.count > 4 {
            encryptedOffset = tiffBase + Int(readUInt32(data, at: tag9416.valueOffset, littleEndian: littleEndian))
        } else {
            encryptedOffset = tag9416.valueOffset
        }

        // Need at least 0x71 bytes from the encrypted block
        guard encryptedOffset + 0x71 <= data.count else { return nil }

        // Decrypt the block - first 4 bytes are the key area, decrypt from offset 0
        let encryptedBlock = data[encryptedOffset..<encryptedOffset + tag9416.count]
        let decrypted = decrypt(Array(encryptedBlock))

        guard decrypted.count > 0x70 else { return nil }
        return Int(decrypted[0x70])
    }

    /// Extract PictureProfile from Sony MakerNote tag 0x9416 as a human-readable name.
    static func extractPictureProfile(from url: URL) -> String? {
        guard let rawValue = extractPictureProfileRawValue(from: url) else { return nil }
        return pictureProfileName(rawValue)
    }

    // MARK: - Decrypt

    /// Decryption lookup table: for each encrypted byte value, gives the original plain value.
    /// Encryption is plain³ mod 249, which is a bijection on {2..248}.
    /// Values 0, 1, 249-255 map to themselves.
    private static let decryptTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0...255 { table[i] = UInt8(i) }
        for plain in 2...248 {
            let encrypted = Int((UInt64(plain) &* UInt64(plain) &* UInt64(plain)) % 249)
            table[encrypted] = UInt8(plain)
        }
        return table
    }()

    private static func decrypt(_ encrypted: [UInt8]) -> [UInt8] {
        encrypted.map { decryptTable[Int($0)] }
    }

    // MARK: - PictureProfile mapping

    private static func pictureProfileName(_ value: Int) -> String? {
        switch value {
        case 0:  return "PP2 (Still Standard)"
        case 10: return "PP1 (Movie)"
        case 22: return "PP3/PP4 (ITU709)"
        case 24: return "PP5 (Cine1)"
        case 25: return "PP6 (Cine2)"
        case 28: return "PP7 (S-Log2)"
        case 31: return "PP8/PP9 (S-Log3)"
        case 32: return "HLG1"
        case 33: return "PP10 (HLG2)"
        case 34: return "HLG3"
        case 35: return "HLG"
        case 36: return "Off"
        case 37: return "FL"
        case 38: return "VV2"
        case 39: return "IN"
        case 40: return "SH"
        case 45: return "HLG Still"
        case 48: return "FL2"
        case 49: return "FL3"
        default: return "Unknown (\(value))"
        }
    }

    // MARK: - TIFF IFD helpers

    private static func readUInt16(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        if littleEndian {
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        } else {
            return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        if littleEndian {
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        } else {
            return (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }
    }

    /// Find a tag in an IFD. Returns the absolute offset of the value/offset field and the data count.
    private static func findTagInIFD(
        data: Data, tiffBase: Int, ifdOffset: Int, tag: UInt16, littleEndian: Bool
    ) -> (valueOffset: Int, count: Int)? {
        let abs = tiffBase + ifdOffset
        guard abs + 2 <= data.count else { return nil }

        let entryCount = Int(readUInt16(data, at: abs, littleEndian: littleEndian))
        guard abs + 2 + entryCount * 12 <= data.count else { return nil }

        for i in 0..<entryCount {
            let entryOffset = abs + 2 + i * 12
            let entryTag = readUInt16(data, at: entryOffset, littleEndian: littleEndian)
            if entryTag == tag {
                let count = Int(readUInt32(data, at: entryOffset + 4, littleEndian: littleEndian))
                let valueOffset = entryOffset + 8 // the 4-byte value/offset field
                return (valueOffset: valueOffset, count: count)
            }
        }
        return nil
    }

    /// Find a byte sequence in Data, starting from the given offset.
    private static func findBytes(_ data: Data, target: [UInt8], from start: Int = 0) -> Int? {
        guard target.count <= data.count, start >= 0 else { return nil }
        let end = data.count - target.count
        guard start <= end else { return nil }
        outer: for i in start...end {
            for j in 0..<target.count {
                if data[i + j] != target[j] { continue outer }
            }
            return i
        }
        return nil
    }
}
