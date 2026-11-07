import Foundation
import MainternanceDomain
import Synchronization

/// In-memory preferences. `holdNextSave` makes the next `save` or `update` wait until `releaseSave()`; a held
/// `update` waits BEFORE its read-modify-write, which then runs as one step (like the real store's lock), so a test
/// can choose which of two writers goes first. `saves` records every value written, by either call.
final class FakePreferencesStore: PreferencesStoring {
    struct State {
        var stored: AppPreferences = .defaults
        var saves: [AppPreferences] = []
        var holdNextSave = false
        /// Every write fails (nothing is stored), as a full disk would.
        var failWrites = false
        /// `load` gives the defaults, as the real store does after a read error.
        var failLoads = false
    }

    let state: Mutex<State>
    let log: CallLog?
    /// One value each time `save` is entered (before it may wait).
    let saveCalls: AsyncStream<Void>
    private let saveCallSource: AsyncStream<Void>.Continuation
    private let gate: AsyncStream<Void>
    private let gateSource: AsyncStream<Void>.Continuation

    /// Judges a recorded run that lies far ahead; the default accepts any date.
    private let now: @Sendable () -> Date

    init(
        _ stored: AppPreferences = .defaults, log: CallLog? = nil,
        now: @escaping @Sendable () -> Date = { .distantFuture }
    ) {
        state = Mutex(State(stored: stored))
        self.log = log
        self.now = now
        (saveCalls, saveCallSource) = AsyncStream.makeStream(of: Void.self)
        (gate, gateSource) = AsyncStream.makeStream(of: Void.self)
    }

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func releaseSave() {
        gateSource.yield()
    }

    func load() async -> AppPreferences {
        state.withLock { $0.failLoads ? .defaults : $0.stored }
    }

    func save(_ preferences: AppPreferences) async -> Bool {
        await waitIfHeld()
        let saved = state.withLock { current -> Bool in
            guard !current.failWrites else { return false }
            current.stored = preferences
            current.saves.append(preferences)
            return true
        }
        log?.add("save")
        return saved
    }

    func update(_ change: @Sendable (inout AppPreferences) -> Void) async -> PreferencesUpdate {
        await waitIfHeld()
        let moment = now()
        let result = state.withLock { current in
            let next = current.stored.updated(now: moment, change)
            guard !current.failWrites else { return PreferencesUpdate(preferences: next, saved: false) }
            current.stored = next
            current.saves.append(next)
            return PreferencesUpdate(preferences: next, saved: true)
        }
        log?.add("save")
        return result
    }

    private func waitIfHeld() async {
        let hold = state.withLock { current -> Bool in
            defer { current.holdNextSave = false }
            return current.holdNextSave
        }
        saveCallSource.yield()
        if hold {
            for await _ in gate {
                break
            }
        }
    }

    var stored: AppPreferences {
        state.withLock { $0.stored }
    }

    var saves: [AppPreferences] {
        state.withLock { $0.saves }
    }
}

struct FakeLoginError: Error, LocalizedError {
    var errorDescription: String? {
        "macOS could not change Launch at login: test refusal"
    }
}

final class FakeLoginItem: LoginItemControlling {
    struct State {
        var status: LoginItemStatus = .disabled
        /// What `setEnabled` leaves behind; nil means "exactly what was asked".
        var resultStatus: LoginItemStatus?
        var fails = false
        var requests: [Bool] = []
    }

    let state = Mutex(State())

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func status() -> LoginItemStatus {
        state.withLock { $0.status }
    }

    func setEnabled(_ enabled: Bool) throws -> LoginItemStatus {
        try state.withLock { current in
            current.requests.append(enabled)
            if current.fails {
                throw FakeLoginError()
            }
            current.status = current.resultStatus ?? (enabled ? .enabled : .disabled)
            return current.status
        }
    }

    var requests: [Bool] {
        state.withLock { $0.requests }
    }
}

final class FakeNotifications: NotificationPosting {
    struct State {
        var authorization: NotificationAuthorization = .notDetermined
        /// What the owner answers when asked.
        var answer: NotificationAuthorization = .allowed
        var requests = 0
        var posted: [UserNotice] = []
    }

    let state: Mutex<State>

    init(_ authorization: NotificationAuthorization = .notDetermined) {
        state = Mutex(State(authorization: authorization))
    }

    func configure(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func authorization() async -> NotificationAuthorization {
        state.withLock { $0.authorization }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        state.withLock { current in
            current.requests += 1
            if current.authorization == .notDetermined {
                current.authorization = current.answer
            }
            return current.authorization
        }
    }

    func post(_ notice: UserNotice) async {
        state.withLock { $0.posted.append(notice) }
    }

    var requests: Int {
        state.withLock { $0.requests }
    }

    var posted: [UserNotice] {
        state.withLock { $0.posted }
    }
}

/// A thread-safe list of values a callback received.
final class Recorded<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func add(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }
}
