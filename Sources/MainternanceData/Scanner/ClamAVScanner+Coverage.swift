import Foundation
import MainternanceDomain

public extension ClamAVScanner {
    /// The folders `scan(scope)` walks and skips, from the same functions the scan itself uses.
    func coverage(of scope: ScanScope) -> ScanCoverage {
        // A root that is itself a symbolic link is left out (when unsure, not covered); the others are resolved.
        let roots = ScanScopes.roots(for: scope, home: home, exists: { FileManager.default.fileExists(atPath: $0) })
            .filter { !CoveragePaths.isSymbolicLink($0) }
            .compactMap { CoveragePaths.realPath($0) }
        let candidates = ScanExclusions.directories(for: scope, home: home, paths: paths)
            .flatMap { [$0, CoveragePaths.realPath($0)].compactMap(\.self) }
        var excluded: [String] = []
        for candidate in candidates where !excluded.contains(candidate) {
            excluded.append(candidate)
        }
        return ScanCoverage(roots: roots, excluded: excluded, resolve: CoveragePaths.resolve)
    }
}
