import MainternanceDomain
import MainternancePresentation
import Testing

struct MenuBarLabelTests {
    @Test func nilOverviewGivesEmptyLabel() {
        let label = MenuBarLabel.make(from: nil)
        #expect(label == MenuBarLabel(symbol: "shield", state: .good, text: ""))
    }

    @Test func needsAttentionOverviewShowsWarningSymbolAndFreeDisk() {
        let label = MenuBarLabel.make(from: makeOverview(state: .needsAttention))
        #expect(label.symbol == "exclamationmark.shield")
        #expect(label.state == .needsAttention)
        #expect(label.text == "41 GB")
    }

    @Test func problemOverviewShowsWarningSymbol() {
        let label = MenuBarLabel.make(from: makeOverview(state: .problem))
        #expect(label.symbol == "exclamationmark.shield")
        #expect(label.state == .problem)
    }

    @Test func goodOverviewShowsCheckmark() {
        let label = MenuBarLabel.make(from: makeOverview(state: .good))
        #expect(label.symbol == "checkmark.shield")
        #expect(label.state == .good)
    }

    @Test func missingOptionalMetricsDoNotBreakTheLabel() {
        let snapshot = makeSnapshot(gpuUsage: nil, temperatureCelsius: nil, battery: nil)
        let label = MenuBarLabel.make(from: makeOverview(state: .good, snapshot: snapshot))
        #expect(label.symbol == "checkmark.shield")
        #expect(label.text == "41 GB")
        #expect(!label.text.hasPrefix("0"))
    }

    @Test func zeroFreeBytesGivesNumericText() {
        let snapshot = makeSnapshot(diskFreeBytes: 0)
        let label = MenuBarLabel.make(from: makeOverview(state: .good, snapshot: snapshot))
        #expect(label.text.first?.isNumber == true)
        #expect(!label.text.contains("Zero"))
    }

    @Test func labelIsSendable() {
        func requireSendable(_: (some Sendable).Type) {}
        requireSendable(MenuBarLabel.self)
    }

    @Test func unreadableDiskGivesEmptyText() {
        var snapshot = makeSnapshot()
        snapshot.diskTotalBytes = 0
        snapshot.diskFreeBytes = 0
        let label = MenuBarLabel.make(from: makeOverview(state: .needsAttention, snapshot: snapshot))
        #expect(label.text == "")
        #expect(label.symbol == "exclamationmark.shield")
    }
}
