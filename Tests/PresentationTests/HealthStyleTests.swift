import MainternanceDomain
import MainternancePresentation
import Testing

struct HealthStyleTests {
    @Test func titlesMatchTheThreeStates() {
        #expect(HealthState.good.title == "Good")
        #expect(HealthState.needsAttention.title == "Needs attention")
        #expect(HealthState.problem.title == "Problem")
    }
}
