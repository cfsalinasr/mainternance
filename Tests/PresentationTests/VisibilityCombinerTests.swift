import MainternancePresentation
import Testing

struct VisibilityCombinerTests {
    @Test func startsHidden() {
        #expect(VisibilityCombiner().isVisible == false)
    }

    @Test func eitherSourceKeepsItVisible() {
        var combiner = VisibilityCombiner()
        #expect(combiner.update(.popover, visible: true) == true)
        #expect(combiner.update(.window, visible: true) == true)
        #expect(combiner.update(.popover, visible: false) == true)
        #expect(combiner.update(.window, visible: false) == false)
    }

    @Test func repeatedReportsDoNotCountTwice() {
        var combiner = VisibilityCombiner()
        _ = combiner.update(.window, visible: true)
        _ = combiner.update(.window, visible: true)
        #expect(combiner.update(.window, visible: false) == false)
    }

    @Test func hidingAnUnseenSourceStaysHidden() {
        var combiner = VisibilityCombiner()
        #expect(combiner.update(.popover, visible: false) == false)
    }
}
