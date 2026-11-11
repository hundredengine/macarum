import Testing
@testable import MacarumCore

@Suite struct WelcomeTests {
    // MARK: Who sees the window

    @Test func aNewInstallSeesTheWelcome() {
        #expect(WelcomeGate.shouldShow(welcomed: false, askedAccessibility: false))
    }

    @Test func itShowsOnlyOnce() {
        #expect(!WelcomeGate.shouldShow(welcomed: true, askedAccessibility: false))
    }

    /// Versions before the welcome window asked for Accessibility at launch and remembered
    /// that; someone who went through that already knows the app.
    @Test func someoneFromAnOlderVersionCountsAsWelcomed() {
        #expect(!WelcomeGate.shouldShow(welcomed: false, askedAccessibility: true))
        #expect(!WelcomeGate.shouldShow(welcomed: true, askedAccessibility: true))
    }

    // MARK: The permission step

    @Test func itStartsByExplaining() {
        #expect(WelcomeFlow(granted: false).step == .explaining)
    }

    @Test func itStartsGrantedWhenThePermissionIsAlreadyThere() {
        #expect(WelcomeFlow(granted: true).step == .granted)
    }

    @Test func askingMovesToWaiting() {
        var flow = WelcomeFlow(granted: false)
        flow.askedForPermission()
        #expect(flow.step == .waiting)
    }

    @Test func aCheckWithoutThePermissionChangesNothing() {
        var flow = WelcomeFlow(granted: false)
        flow.permissionChecked(granted: false)
        #expect(flow.step == .explaining)
        flow.askedForPermission()
        flow.permissionChecked(granted: false)
        #expect(flow.step == .waiting)
    }

    @Test func thePermissionArrivingWhileWaitingMovesToGranted() {
        var flow = WelcomeFlow(granted: false)
        flow.askedForPermission()
        flow.permissionChecked(granted: true)
        #expect(flow.step == .granted)
    }

    /// Switched on in System Settings by hand, without pressing the button.
    @Test func thePermissionArrivingWhileExplainingMovesToGranted() {
        var flow = WelcomeFlow(granted: false)
        flow.permissionChecked(granted: true)
        #expect(flow.step == .granted)
    }

    @Test func askingAgainOnceGrantedChangesNothing() {
        var flow = WelcomeFlow(granted: true)
        flow.askedForPermission()
        #expect(flow.step == .granted)
    }

    @Test func takingThePermissionAwayGoesBackToWhereItWas() {
        var asked = WelcomeFlow(granted: false)
        asked.askedForPermission()
        asked.permissionChecked(granted: true)
        asked.permissionChecked(granted: false)
        #expect(asked.step == .waiting)

        var neverAsked = WelcomeFlow(granted: true)
        neverAsked.permissionChecked(granted: false)
        #expect(neverAsked.step == .explaining)
    }
}
