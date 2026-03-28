import Foundation

/// 輕量 value-type，代表單一媒體檔案。
/// 取代 SwiftData Photo @Model 在 UI 層的角色，不寫入資料庫。
struct PhotoItem: Identifiable, Sendable {
    let filePath: String
    let fileName: String
    var dateTaken: Date
    var fileSize: Int64 = 0
    var isVideo: Bool = false
    var duration: Double? = nil
    var livePhotoMovPath: String? = nil
    var isLivePhotoMov: Bool = false
    var editOps: [EditOp] = []

    // EXIF / video metadata（在 PhotoDetailView 開啟時才載入）
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var orientation: Int? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var lensModel: String? = nil
    var software: String? = nil
    var focalLength: Double? = nil
    var aperture: Double? = nil
    var shutterSpeed: String? = nil
    var iso: Int? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var headroom: Double? = nil
    var profileName: String? = nil
    var colorDepth: Int? = nil
    var dpiWidth: Double? = nil
    var dpiHeight: Double? = nil
    var offsetTimeOriginal: String? = nil
    var exposureBias: Double? = nil
    var exposureProgram: Int? = nil
    var meteringMode: Int? = nil
    var flash: Int? = nil
    var whiteBalance: Int? = nil
    var brightnessValue: Double? = nil
    var focalLenIn35mm: Int? = nil
    var sceneCaptureType: Int? = nil
    var lightSource: Int? = nil
    var lensSpecification: [Double]? = nil
    var exifVersion: String? = nil
    var imageStabilization: Int? = nil
    var contrast: Int? = nil
    var saturation: Int? = nil
    var sharpness: Int? = nil
    var digitalZoomRatio: Double? = nil
    var videoCodec: String? = nil
    var audioCodec: String? = nil

    var id: String { filePath }
    var compositeEdit: CompositeEdit { CompositeEdit.from(editOps) }
    var fileURL: URL { URL(fileURLWithPath: filePath) }

    /// 從 EXIFData 更新圖片 metadata 欄位。
    mutating func applyEXIF(_ exif: EXIFData) {
        if let w = exif.pixelWidth { pixelWidth = w }
        if let h = exif.pixelHeight { pixelHeight = h }
        orientation = exif.orientation
        cameraMake = exif.cameraMake
        cameraModel = exif.cameraModel
        lensModel = exif.lensModel
        software = exif.software
        focalLength = exif.focalLength
        aperture = exif.aperture
        shutterSpeed = exif.shutterSpeed
        iso = exif.iso
        latitude = exif.latitude
        longitude = exif.longitude
        headroom = exif.headroom
        profileName = exif.profileName
        colorDepth = exif.colorDepth
        dpiWidth = exif.dpiWidth
        dpiHeight = exif.dpiHeight
        offsetTimeOriginal = exif.offsetTimeOriginal
        exposureBias = exif.exposureBias
        exposureProgram = exif.exposureProgram
        meteringMode = exif.meteringMode
        flash = exif.flash
        whiteBalance = exif.whiteBalance
        brightnessValue = exif.brightnessValue
        focalLenIn35mm = exif.focalLenIn35mm
        sceneCaptureType = exif.sceneCaptureType
        lightSource = exif.lightSource
        lensSpecification = exif.lensSpecification
        exifVersion = exif.exifVersion
        imageStabilization = exif.imageStabilization
        contrast = exif.contrast
        saturation = exif.saturation
        sharpness = exif.sharpness
        digitalZoomRatio = exif.digitalZoomRatio
        if let d = exif.dateTaken { dateTaken = d }
    }

    /// 從 VideoMetadata 更新影片 metadata 欄位。
    mutating func applyVideoMetadata(_ meta: VideoMetadata) {
        if let d = meta.duration { duration = d }
        if let w = meta.pixelWidth { pixelWidth = w }
        if let h = meta.pixelHeight { pixelHeight = h }
        videoCodec = meta.videoCodec
        audioCodec = meta.audioCodec
        if let d = meta.creationDate { dateTaken = d }
        if let lat = meta.latitude { latitude = lat }
        if let lon = meta.longitude { longitude = lon }
    }

    /// 依路徑 prefix 從已知資料夾找 bookmark data。
    func resolveBookmarkData(from folders: [ScannedFolder]) -> Data? {
        folders.first { filePath.hasPrefix($0.path) }?.bookmarkData
    }
}
