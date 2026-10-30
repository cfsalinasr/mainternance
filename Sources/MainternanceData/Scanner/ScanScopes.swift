import Foundation
import MainternanceDomain

/// Which folders a scan covers. Pure: existence is injected, nothing touches the disk here.
public enum ScanScopes {
    /// The absolute, standardized, de-duplicated roots to hand to `clamscan` for `scope`.
    ///
    /// Only existing paths are kept. A root nested inside another root is dropped (no double scanning), and `/`
    /// itself is never returned. The order is stable: the order of the scope's list, minus dropped entries.
    public static func roots(for scope: ScanScope, home: URL, exists: (String) -> Bool) -> [String] {
        let candidates: [String] = switch scope {
        case .quick:
            [
                home.appendingPathComponent("Downloads").path,
                home.appendingPathComponent("Desktop").path,
                "/Applications",
                home.appendingPathComponent("Library/LaunchAgents").path,
                "/Library/LaunchAgents",
                "/Library/LaunchDaemons"
            ]
        case .full:
            [home.path, "/Applications"]
        case let .custom(url):
            [url.path]
        }
        var seen: [String] = []
        for candidate in candidates {
            guard candidate.hasPrefix("/") else { continue }
            let path = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard path != "/", path.hasPrefix("/"), !seen.contains(path), exists(path) else { continue }
            seen.append(path)
        }
        return seen.filter { path in
            !seen.contains { other in other != path && path.hasPrefix(other + "/") }
        }
    }
}
