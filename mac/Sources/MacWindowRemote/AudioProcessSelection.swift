import CoreAudio

/// Which Core Audio process objects the "App" audio mode taps for the viewed window's app (D39).
enum AudioProcessSelection {
    struct Process: Equatable {
        var object: AudioObjectID
        var pid: pid_t
        var bundleID: String
    }

    /// Safari plays web audio from WebKit's shared GPU process, which has no Safari bundle-ID
    /// prefix (D39 limitation).
    static let webKitBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let webKitGPUProcess = "com.apple.WebKit.GPU"

    /// The app's own process (`pid`), every process whose bundle ID is `bundleID` or starts with
    /// `bundleID + "."` (helpers such as `com.google.Chrome.helper.Renderer`), and for Safari
    /// the WebKit GPU process. Never our own process (`ownPid`). In list order.
    static func objects(bundleID: String?, pid: pid_t, ownPid: pid_t, in processes: [Process]) -> [AudioObjectID] {
        let bid = bundleID ?? ""
        let webKit = webKitBrowsers.contains(bid)
        return processes.filter { p in
            guard p.pid != ownPid else { return false }
            if p.pid == pid { return true }
            guard !bid.isEmpty else { return false }
            if p.bundleID == bid || p.bundleID.hasPrefix(bid + ".") { return true }
            return webKit && p.bundleID == webKitGPUProcess
        }.map(\.object)
    }
}
