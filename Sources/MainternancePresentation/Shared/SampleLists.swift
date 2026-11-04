import Foundation

/// Shared sample-list helpers.
enum SampleLists {
    static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { $0 + max($1, 0) }
    }
}
