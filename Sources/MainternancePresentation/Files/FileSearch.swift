import Foundation

enum SizeFilter: String, CaseIterable, Identifiable, Sendable {
    case any, over1MB, over100MB, over1GB

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .any: "Any size"
        case .over1MB: "Over 1 MB"
        case .over100MB: "Over 100 MB"
        case .over1GB: "Over 1 GB"
        }
    }

    var minimumBytes: Int64 {
        switch self {
        case .any: 0
        case .over1MB: 1_000_000
        case .over100MB: 100_000_000
        case .over1GB: 1_000_000_000
        }
    }
}

enum DateFilter: String, CaseIterable, Identifiable, Sendable {
    case any, pastDay, pastWeek, pastMonth, pastYear

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .any: "Any date"
        case .pastDay: "Past day"
        case .pastWeek: "Past week"
        case .pastMonth: "Past month"
        case .pastYear: "Past year"
        }
    }

    var days: Double? {
        switch self {
        case .any: nil
        case .pastDay: 1
        case .pastWeek: 7
        case .pastMonth: 30
        case .pastYear: 365
        }
    }
}

struct FileSearchCriteria: Equatable, Sendable {
    var text = ""
    var kind: FileKind?
    var size: SizeFilter = .any
    var date: DateFilter = .any

    var isActive: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || kind != nil || size != .any || date != .any
    }
}

enum FileSearch {
    /// Case-insensitive match on name and path, combined with the type, size and date filters.
    static func filter(_ files: [SampleFile], criteria: FileSearchCriteria, now: Date = Date()) -> [SampleFile] {
        let query = criteria.text.trimmingCharacters(in: .whitespaces)
        let cutoff = criteria.date.days.map { now.addingTimeInterval(-$0 * 86400) }
        return files.filter { file in
            if !query.isEmpty,
               !file.name.localizedCaseInsensitiveContains(query),
               !file.path.localizedCaseInsensitiveContains(query)
            {
                return false
            }
            if let kind = criteria.kind, file.kind != kind {
                return false
            }
            if file.size < criteria.size.minimumBytes {
                return false
            }
            if let cutoff, file.modified < cutoff {
                return false
            }
            return true
        }
    }
}
