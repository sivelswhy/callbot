import Foundation

/// ~/.callbot: models, profile and debug log
public enum DataDirectory {
    public static let url: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".callbot")
        // The app used to be called PhoneBT: keep the files of an earlier install
        let legacy = home.appendingPathComponent(".phonebt")
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        return dir
    }()

    public static var path: String { url.path }
}
