import Foundation

/// Shared accessibility identifiers for XCUITest.
enum AccessibilityID {
    // MARK: - Content View
    static let sidebar = "sidebar"
    static let importButton = "toolbar.import"
    static let fullScreenButton = "toolbar.fullScreen"
    static let backButton = "toolbar.back"
    static let searchField = "toolbar.search"

    // MARK: - Sidebar
    static let sidebarList = "sidebar.list"
    static let sidebarFoldersSection = "sidebar.folders"
    static let sidebarEmptyMessage = "sidebar.empty"
    static let sidebarProgressBar = "sidebar.progress"

    // MARK: - Grid
    static let photoGrid = "grid.photos"
    static let gridEmptyState = "grid.empty"

    // MARK: - Detail
    static let detailView = "detail.view"
    static let detailInspectorToggle = "detail.inspectorToggle"

    // MARK: - Video Control Bar
    static let videoPlayPause = "video.playPause"
    static let videoScrubber = "video.scrubber"
    static let videoMuteToggle = "video.muteToggle"
    static let videoVolumeSlider = "video.volume"
    static let videoElapsedTime = "video.elapsed"
    static let videoTotalTime = "video.total"

    // MARK: - Settings
    static let settingsGeneral = "settings.general"
    static let settingsCache = "settings.cache"
    static let settingsGyro = "settings.gyro"
    static let settingsThemePicker = "settings.theme"
    static let settingsDiagBadgeToggle = "settings.diagBadge"
    static let settingsBufferPicker = "settings.buffer"
    static let settingsLogLevelPicker = "settings.logLevel"
    static let settingsCacheSlider = "settings.cacheSlider"
    static let settingsResetButton = "settings.resetAllData"

    // MARK: - Import Panel
    static let importPanel = "import.panel"
    static let importCloseButton = "import.close"
    static let importFileList = "import.fileList"

    // MARK: - Task Progress Bar
    static let taskProgressBar = "taskProgress"
}
