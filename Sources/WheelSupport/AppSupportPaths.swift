import Foundation

public enum AppSupportPaths {
    public static func directory(forAppNamed appName: String) -> URL {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fm.temporaryDirectory.appendingPathComponent(appName, isDirectory: true)
        }

        let appDirectory = appSupport.appendingPathComponent(appName, isDirectory: true)
        if !fm.fileExists(atPath: appDirectory.path) {
            try? fm.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }

        return appDirectory
    }
}
