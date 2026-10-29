import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

struct DetailsStateTests {
    private func sample(
        _ index: Int,
        cpu: Double? = 0.2,
        gpu: Double? = nil,
        memory: MemoryPressure? = nil
    ) -> OverviewSample {
        OverviewSample(cpu: cpu, gpu: gpu, memoryPressure: memory, at: Date(timeIntervalSince1970: Double(index)))
    }

    @Test func collectingUntilTwoSamplesHaveAValue() {
        #expect(DetailsState(history: []) == .collecting)
        #expect(DetailsState(history: [sample(0)]) == .collecting)
        #expect(DetailsState(history: [sample(0), sample(1)]) == .ready)
        #expect(DetailsState(history: (0 ..< 30).map { sample($0) }) == .ready)
    }

    @Test func samplesWithoutAnyValueDoNotCount() {
        let empty = sample(1, cpu: nil)
        #expect(DetailsState(history: [sample(0), empty]) == .collecting)
        #expect(DetailsState(history: [empty, empty, empty]) == .collecting)
        // A gpu-only or memory-only sample has a value too.
        #expect(DetailsState(history: [sample(0, cpu: nil, gpu: 0.3), sample(1, cpu: nil, memory: .normal)]) == .ready)
    }

    @Test func collectingTextIsPinned() {
        #expect(DetailsState.collectingText == "Collecting data…")
    }

    @Test func aRowNeedsTwoValuesToBeDrawn() {
        let one = HistorySeries(history: [sample(0, gpu: 0.4), sample(1, gpu: nil)])
        #expect(one.gpu == nil)
        #expect(one.cpu?.count == 2)
        let single = HistorySeries(history: [sample(0, memory: .warning)])
        #expect(single.memory == nil)
        #expect(single.cpu == nil)
        let two = HistorySeries(history: [sample(0, gpu: 0.4), sample(1, gpu: 0.6)])
        #expect(two.gpu == [0.4, 0.6])
    }
}
