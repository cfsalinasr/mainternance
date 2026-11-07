import Foundation
import Testing

/// The fake clock itself: a release between a sleep's two steps is never lost, and a wait that never ends fails
/// instead of hanging the run.
struct FakeSleeperTests {
    @Test func aReleaseBetweenRegisterAndSuspendIsNotLost() async {
        let sleeper = FakeSleeper()
        let id = await sleeper.register(.seconds(60))
        await sleeper.waitForSleeps(1)
        await sleeper.releaseAll() // lands before the sleep suspended
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await (try? sleeper.suspend(id)) != nil }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(returned) // without the fix this suspend waits forever
    }

    @Test func waitingForASleepThatNeverComesFailsInsteadOfHanging() async {
        let sleeper = FakeSleeper(timeout: .milliseconds(50))
        await withKnownIssue {
            await sleeper.waitForSleeps(1)
        }
    }
}
