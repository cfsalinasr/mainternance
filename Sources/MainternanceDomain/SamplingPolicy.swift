public struct SamplingPolicy: Sendable {
    public var visible: Duration
    public var hidden: Duration

    public init(visible: Duration = .seconds(2), hidden: Duration = .seconds(45)) {
        self.visible = visible
        self.hidden = hidden
    }

    public func interval(isVisible: Bool, isLowPowerMode: Bool) -> Duration {
        let base = isVisible ? visible : hidden
        return isLowPowerMode ? base * 2 : base
    }
}
