import MainternanceDomain
import Testing

struct SamplingPolicyTests {
    @Test func intervals() {
        let policy = SamplingPolicy()
        #expect(policy.interval(isVisible: true, isLowPowerMode: false) == .seconds(2))
        #expect(policy.interval(isVisible: false, isLowPowerMode: false) == .seconds(45))
        #expect(policy.interval(isVisible: true, isLowPowerMode: true) == .seconds(4))
        #expect(policy.interval(isVisible: false, isLowPowerMode: true) == .seconds(90))
    }
}
