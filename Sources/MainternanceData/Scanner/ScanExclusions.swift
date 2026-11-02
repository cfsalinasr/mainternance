import Foundation
import MainternanceDomain

/// Directories a scan must never enter, and the `clamscan` options that say so. Pure.
public enum ScanExclusions {
    /// Absolute, standardized directories excluded from every scan of `scope`:
    /// - the quarantine folder and the ClamAV folder (the app's own state: quarantined malware must not be
    ///   reported again, and the signature database is full of byte patterns that look like malware);
    /// - for FULL scans, `~/Library/Mobile Documents` (iCloud Drive) and `~/Library/CloudStorage` (Dropbox, Google
    ///   Drive, OneDrive providers). Reading a cloud placeholder file makes the provider DOWNLOAD it, so a scan
    ///   would pull the user's whole cloud content onto the disk. This is advisory in the UI: those files are not
    ///   scanned, and the scan summary must not claim they were.
    public static func directories(for scope: ScanScope, home: URL, paths: ClamAVPaths) -> [String] {
        var directories = [paths.quarantineDirectory.path, paths.root.path]
        if scope == .full {
            directories.append(home.appendingPathComponent("Library/Mobile Documents").path)
            directories.append(home.appendingPathComponent("Library/CloudStorage").path)
        }
        var result: [String] = []
        for directory in directories {
            let path = URL(fileURLWithPath: directory).standardizedFileURL.path
            if ScanPathRules.isPlainAbsolute(path), !result.contains(path) {
                result.append(path)
            }
        }
        return result
    }

    /// POSIX extended regex for `--exclude-dir`. Upstream (`clamscan/manager.c` `scandirs`, `common/misc.c`
    /// `match_regex`) runs `regexec` UNANCHORED against the directory path as it is being walked, so the pattern
    /// anchors itself: `^<escaped path>(/|$)` matches the directory and everything below, but not `<path>2`.
    /// The pattern does not end in `/`, so `match_regex` does not append one to the candidate path.
    public static func regex(forDirectory path: String) -> String {
        "^" + escape(path) + "(/|$)"
    }

    /// One `--exclude-dir=<regex>` argument per directory (each is a single argv element, so a hostile name
    /// cannot add an option).
    public static func arguments(for directories: [String]) -> [String] {
        directories.map { "--exclude-dir=" + regex(forDirectory: $0) }
    }

    private static let metacharacters = Set("\\^$.|?*+()[]{}")

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if metacharacters.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
