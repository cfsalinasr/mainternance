import Foundation
import MainternanceDomain
@testable import MainternancePresentation
import Testing

@MainActor
struct ScannerViewModelTests {
    // MARK: Status and canStartScan

    @Test func startsUnknownAndCannotScan() {
        let rig = ScannerRig()
        #expect(rig.model.engine == nil)
        #expect(rig.model.run == .idle)
        #expect(!rig.model.canStartScan)
        #expect(!rig.model.canInstall)
        #expect(rig.model.findings.isEmpty)
    }

    @Test func refreshStatusPublishesTheEngineStatus() async {
        let rig = ScannerRig()
        rig.engine.configure { $0.status = .notInstalled }
        await rig.model.refreshStatus()
        #expect(rig.model.engine == .notInstalled)
        rig.engine.configure { $0.status = .ready(definitionsAge: 5) }
        await rig.model.refreshStatus()
        #expect(rig.model.engine == .ready(definitionsAge: 5))
    }

    @Test func canStartScanFollowsTheEngineState() async {
        let cases: [(EngineStatus, Bool)] = [
            (.ready(definitionsAge: 10), true),
            (.updateNeeded(definitionsAge: 900_000), true),
            (.updateNeeded(definitionsAge: nil), false), // no definitions at all: the engine would refuse
            (.notInstalled, false),
            (.homebrewMissing, false),
            (.installing(stage: "x"), false),
            (.downloadingDefinitions, false),
            (.failed(message: "boom"), false)
        ]
        for (status, expected) in cases {
            let rig = ScannerRig()
            rig.engine.configure { $0.status = status }
            await rig.model.refreshStatus()
            #expect(rig.model.canStartScan == expected, "\(status)")
        }
    }

    // MARK: Install and definitions

    @Test func installFlowEndsIdleWithTheRefreshedStatus() async {
        let rig = ScannerRig()
        rig.engine.configure {
            $0.status = .notInstalled
            $0.installEvents = [.stage("Downloading ClamAV…"), .progress(0.5), .finished]
            $0.statusAfterInstall = .updateNeeded(definitionsAge: nil)
        }
        await rig.model.refreshStatus()
        #expect(rig.model.canInstall)
        await rig.model.install()
        #expect(rig.model.run == .idle)
        #expect(rig.model.engine == .updateNeeded(definitionsAge: nil))
        #expect(rig.model.errorMessage == nil)
    }

    @Test func installFailureShowsTheMessageAndKeepsTheEngineState() async {
        let rig = ScannerRig()
        rig.engine.configure {
            $0.status = .notInstalled
            $0.installEvents = [.stage("Downloading ClamAV…"), .failed(message: "Homebrew failed (exit 1): Error: x")]
        }
        await rig.model.refreshStatus()
        await rig.model.install()
        #expect(rig.model.run == .idle)
        #expect(rig.model.engine == .notInstalled)
        #expect(rig.model.errorMessage == "Homebrew failed (exit 1): Error: x")
    }

    @Test func installIsOnlyOfferedWhenTheEngineIsNotInstalled() async {
        let rig = await ScannerRig.ready()
        rig.engine.configure { $0.installEvents = [.failed(message: "should not run")] }
        await rig.model.install()
        #expect(rig.model.errorMessage == nil)
        #expect(rig.model.run == .idle)
    }

    @Test func installEventsMapToRunStateWithClampedProgress() async {
        let rig = ScannerRig()
        rig.engine.configure { $0.status = .notInstalled; $0.holdInstall = true }
        await rig.model.refreshStatus()
        let install = Task { await rig.model.install() }
        var calls = rig.engine.installCalls.makeAsyncIterator()
        _ = await calls.next()
        #expect(rig.model.run == .installing(stage: "Starting the install…", progress: nil))
        #expect(!rig.model.canInstall)
        #expect(!rig.model.canStartScan)
        rig.engine.emitInstall(.stage("Installing ClamAV…"))
        #expect(await rig.model.wait { rig.model.run == .installing(stage: "Installing ClamAV…", progress: nil) })
        rig.engine.emitInstall(.progress(0.25))
        #expect(await rig.model.wait { rig.model.run == .installing(stage: "Installing ClamAV…", progress: 0.25) })
        rig.engine.emitInstall(.progress(7))
        #expect(await rig.model.wait { rig.model.run == .installing(stage: "Installing ClamAV…", progress: 1) })
        rig.engine.emitInstall(.progress(.nan))
        #expect(await rig.model.wait { rig.model.run == .installing(stage: "Installing ClamAV…", progress: 0) })
        rig.engine.emitInstall(.progress(nil))
        #expect(await rig.model.wait { rig.model.run == .installing(stage: "Installing ClamAV…", progress: nil) })
        rig.engine.finishInstall()
        await install.value
        #expect(rig.model.run == .idle)
    }

    @Test func updateDefinitionsRefreshesTheStatusAndReportsFailure() async {
        let rig = ScannerRig()
        rig.engine.configure {
            $0.status = .updateNeeded(definitionsAge: 900_000)
            $0.updateEvents = [.stage("Downloading definitions…"), .progress(0.4), .finished]
            $0.statusAfterUpdate = .ready(definitionsAge: 3)
        }
        await rig.model.refreshStatus()
        await rig.model.updateDefinitions()
        #expect(rig.model.engine == .ready(definitionsAge: 3))
        #expect(rig.model.errorMessage == nil)
        rig.engine.configure { $0.updateEvents = [.failed(message: "Updating definitions failed (exit 1)")] }
        await rig.model.updateDefinitions()
        #expect(rig.model.errorMessage == "Updating definitions failed (exit 1)")
        #expect(!rig.model.run.isWorking)
    }
}
