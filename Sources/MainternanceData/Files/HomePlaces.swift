import Foundation

/// Where a path lies inside the home folder, by folder names: the one rule the searcher and the trasher share for
/// "inside the home folder", "in `~/Library`, a dot-folder or a dot-file" and "inside a package".
enum HomePlaces {
    /// The folder names from `home` down to `folder`, both already resolved (`realpath`): empty when `folder` is the
    /// home folder itself, nil when it is not inside the home folder.
    static func names(from home: String, to folder: String) -> [Substring]? {
        if folder == home {
            return []
        }
        guard folder.hasPrefix(home + "/") else { return nil }
        return folder.dropFirst(home.count + 1).split(separator: "/", omittingEmptySubsequences: true)
    }

    /// The names lead into `~/Library` (the first name is `Library`, in any letter case) or through a name that
    /// starts with `.`.
    static func isHidden(_ names: [Substring]) -> Bool {
        if let first = names.first, first.caseInsensitiveCompare("Library") == .orderedSame {
            return true
        }
        return names.contains(where: isHiddenName)
    }

    /// A name that starts with `.`: hidden in Finder. Search, Large files, Duplicates and the trasher all leave such
    /// a file or folder alone.
    static func isHiddenName(_ name: some StringProtocol) -> Bool {
        name.hasPrefix(".")
    }

    /// Whether any folder from just below `home` down to the end of `names` is a package (an app, a Photos library,
    /// anything macOS shows as one item). The home folder itself is not asked: it is where every walk starts.
    static func isInsidePackage(home: String, names: [Substring], isPackage: (String) -> Bool) -> Bool {
        var folder = home
        for name in names {
            folder = (folder as NSString).appendingPathComponent(String(name))
            if isPackage(folder) {
                return true
            }
        }
        return false
    }
}
