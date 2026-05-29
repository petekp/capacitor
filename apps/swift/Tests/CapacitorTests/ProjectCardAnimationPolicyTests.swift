@testable import Capacitor
import Foundation
import XCTest

final class ProjectCardAnimationPolicyTests: XCTestCase {
    func testPressedInteractionStateUsesPressedScale() {
        var state = ProjectCardInteractionState()
        state.isHovered = true
        state.isPressed = true

        let scale = state.cardScale(
            layoutMode: .vertical,
            reduceMotion: false,
            isDragging: false,
            config: .shared,
        )

        XCTAssertEqual(scale, GlassConfig.shared.cardPressedScale(for: .vertical))
    }

    func testHoverInteractionStateUsesHoverScaleWhenNotPressed() {
        var state = ProjectCardInteractionState()
        state.isHovered = true

        let scale = state.cardScale(
            layoutMode: .dock,
            reduceMotion: false,
            isDragging: false,
            config: .shared,
        )

        XCTAssertEqual(scale, GlassConfig.shared.cardHoverScale(for: .dock))
    }

    func testPressTiltUsesPressPointAndCardSize() {
        var state = ProjectCardInteractionState()
        state.isPressed = true
        state.pressPoint = CGPoint(x: 180, y: 10)
        state.cardSize = CGSize(width: 200, height: 100)

        let tiltX = state.pressTiltX(reduceMotion: false, config: .shared)
        let tiltY = state.pressTiltY(reduceMotion: false, config: .shared)

        XCTAssertEqual(tiltX, GlassConfig.shared.cardPressTiltVertical * 0.8, accuracy: 0.0001)
        XCTAssertEqual(tiltY, GlassConfig.shared.cardPressTiltHorizontal * 0.8, accuracy: 0.0001)
    }

    func testPressTiltCollapsesWhenReducedMotionIsEnabled() {
        var state = ProjectCardInteractionState()
        state.isPressed = true
        state.pressPoint = CGPoint(x: 100, y: 50)
        state.cardSize = CGSize(width: 200, height: 100)

        XCTAssertEqual(state.pressTiltX(reduceMotion: true, config: .shared), 0)
        XCTAssertEqual(state.pressTiltY(reduceMotion: true, config: .shared), 0)
    }

    func testWaitingCardAnimatesWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: true,
            isWorking: false,
        )

        XCTAssertTrue(shouldAnimate)
    }

    func testIdleCardDoesNotAnimateWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: false,
            isWorking: false,
        )

        XCTAssertFalse(shouldAnimate)
    }

    func testWorkingCardAnimatesWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: false,
            isWorking: true,
        )

        XCTAssertTrue(shouldAnimate)
    }

    func testLayerOpacitiesForIdleDisableAllDynamicLayers() {
        let opacities = CardLayerOpacityPolicy.opacities(for: .idle)

        XCTAssertEqual(opacities.readyAmbient, 0)
        XCTAssertEqual(opacities.readyBorder, 0)
        XCTAssertEqual(opacities.waitingAmbient, 0)
        XCTAssertEqual(opacities.waitingBorder, 0)
        XCTAssertEqual(opacities.workingStripe, 0)
        XCTAssertEqual(opacities.workingBorder, 0)
    }

    func testLayerOpacitiesForWorkingKeepResidualWaitingPulse() {
        let opacities = CardLayerOpacityPolicy.opacities(for: .working)

        XCTAssertEqual(opacities.workingStripe, 1.0)
        XCTAssertEqual(opacities.workingBorder, 1.0)
        XCTAssertGreaterThan(opacities.waitingAmbient, 0.0)
        XCTAssertGreaterThan(opacities.waitingBorder, 0.0)
        XCTAssertEqual(opacities.readyAmbient, 0.0)
        XCTAssertEqual(opacities.readyBorder, 0.0)
    }

    func testLayerOpacitiesForReadyShowOnlyReadyLayers() {
        let opacities = CardLayerOpacityPolicy.opacities(for: .ready)

        XCTAssertEqual(opacities.readyAmbient, 1.0)
        XCTAssertEqual(opacities.readyBorder, 1.0)
        XCTAssertEqual(opacities.workingStripe, 0.0)
        XCTAssertEqual(opacities.workingBorder, 0.0)
        XCTAssertEqual(opacities.waitingAmbient, 0.0)
        XCTAssertEqual(opacities.waitingBorder, 0.0)
    }

    func testLayerOpacitiesForCompactingShowOnlyWaitingLayers() {
        let opacities = CardLayerOpacityPolicy.opacities(for: .compacting)

        XCTAssertGreaterThan(opacities.waitingAmbient, 0.0)
        XCTAssertGreaterThan(opacities.waitingBorder, 0.0)
        XCTAssertEqual(opacities.workingStripe, 0.0)
        XCTAssertEqual(opacities.workingBorder, 0.0)
        XCTAssertEqual(opacities.readyAmbient, 0.0)
        XCTAssertEqual(opacities.readyBorder, 0.0)
    }

    func testReadyChimeRespectsUserSetting() {
        let shouldPlay = ReadyChimePolicy.shouldPlay(
            playReadyChime: false,
            oldState: .working,
            newState: .ready,
        )

        XCTAssertFalse(shouldPlay)
    }

    func testReadyChimePolicyRequiresTransitionIntoReady() {
        let shouldPlay = ReadyChimePolicy.shouldPlay(
            playReadyChime: true,
            oldState: .ready,
            newState: .ready,
        )

        XCTAssertFalse(shouldPlay)
    }

    func testReadyChimePlaysWhenTransitioningToReady() {
        let shouldPlay = ReadyChimePolicy.shouldPlay(
            playReadyChime: true,
            oldState: .waiting,
            newState: .ready,
        )

        XCTAssertTrue(shouldPlay)
    }

    func testReadyChimePlaysWhenInitialStateIsReady() {
        let shouldPlay = ReadyChimePolicy.shouldPlay(
            playReadyChime: true,
            oldState: nil,
            newState: .ready,
        )

        XCTAssertTrue(shouldPlay)
    }

    @MainActor
    func testReadyChimeGatePreventsDuplicateReadyTransitionAcrossCallers() {
        let gate = ReadyChimeGate()

        let first = gate.shouldPlay(
            projectPath: "/tmp/project-a",
            source: .sessionState,
            playReadyChime: true,
            reportedOldState: .working,
            newState: .ready,
        )
        let duplicate = gate.shouldPlay(
            projectPath: "/tmp/project-a",
            source: .sessionState,
            playReadyChime: true,
            reportedOldState: .working,
            newState: .ready,
        )

        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
    }

    @MainActor
    func testReadyChimeGateAllowsRapidDistinctTransitionsIntoReady() {
        let gate = ReadyChimeGate()
        let projectPath = "/tmp/project-b"

        let firstReady = gate.shouldPlay(
            projectPath: projectPath,
            source: .visibleState,
            playReadyChime: true,
            reportedOldState: .working,
            newState: .ready,
        )
        let leaveReady = gate.shouldPlay(
            projectPath: projectPath,
            source: .visibleState,
            playReadyChime: true,
            reportedOldState: .ready,
            newState: .working,
        )
        let secondReady = gate.shouldPlay(
            projectPath: projectPath,
            source: .visibleState,
            playReadyChime: true,
            reportedOldState: .working,
            newState: .ready,
        )

        XCTAssertTrue(firstReady)
        XCTAssertFalse(leaveReady)
        XCTAssertTrue(secondReady)
    }

    // MARK: - Layer Opacity Completeness

    /// Every SessionState must produce a valid opacity set — no state should be unhandled.
    func testLayerOpacitiesExistForAllSessionStates() {
        let allStates: [SessionState] = [.idle, .ready, .working, .waiting, .compacting]

        for state in allStates {
            let opacities = CardLayerOpacityPolicy.opacities(for: state)
            // All opacity values must be in [0, 1]
            XCTAssertGreaterThanOrEqual(opacities.readyAmbient, 0, "\(state) readyAmbient < 0")
            XCTAssertLessThanOrEqual(opacities.readyAmbient, 1, "\(state) readyAmbient > 1")
            XCTAssertGreaterThanOrEqual(opacities.readyBorder, 0, "\(state) readyBorder < 0")
            XCTAssertLessThanOrEqual(opacities.readyBorder, 1, "\(state) readyBorder > 1")
            XCTAssertGreaterThanOrEqual(opacities.waitingAmbient, 0, "\(state) waitingAmbient < 0")
            XCTAssertLessThanOrEqual(opacities.waitingAmbient, 1, "\(state) waitingAmbient > 1")
            XCTAssertGreaterThanOrEqual(opacities.waitingBorder, 0, "\(state) waitingBorder < 0")
            XCTAssertLessThanOrEqual(opacities.waitingBorder, 1, "\(state) waitingBorder > 1")
            XCTAssertGreaterThanOrEqual(opacities.workingStripe, 0, "\(state) workingStripe < 0")
            XCTAssertLessThanOrEqual(opacities.workingStripe, 1, "\(state) workingStripe > 1")
            XCTAssertGreaterThanOrEqual(opacities.workingBorder, 0, "\(state) workingBorder < 0")
            XCTAssertLessThanOrEqual(opacities.workingBorder, 1, "\(state) workingBorder > 1")
            XCTAssertGreaterThanOrEqual(opacities.activeRing, 0, "\(state) activeRing < 0")
            XCTAssertLessThanOrEqual(opacities.activeRing, 1, "\(state) activeRing > 1")
        }
    }

    /// Idle must disable the active ring — no glow should appear on idle cards.
    func testIdleHasZeroActiveRing() {
        let opacities = CardLayerOpacityPolicy.opacities(for: .idle)
        XCTAssertEqual(opacities.activeRing, 0, "Idle cards must not show an active ring")
    }

    /// No state should have both ready AND working layers at full opacity simultaneously.
    /// This would cause a visual clash of green + gold effects.
    func testNoStateMixesReadyAndWorkingAtFullOpacity() {
        let allStates: [SessionState] = [.idle, .ready, .working, .waiting, .compacting]

        for state in allStates {
            let opacities = CardLayerOpacityPolicy.opacities(for: state)
            let hasFullReady = opacities.readyAmbient >= 1.0 || opacities.readyBorder >= 1.0
            let hasFullWorking = opacities.workingStripe >= 1.0 || opacities.workingBorder >= 1.0

            XCTAssertFalse(
                hasFullReady && hasFullWorking,
                "\(state) has both ready and working layers at full opacity — visual clash",
            )
        }
    }

    /// Every non-idle state must show at least one visual indicator (ambient, border, or stripe).
    func testNonIdleStatesHaveAtLeastOneVisibleLayer() {
        let activeStates: [SessionState] = [.ready, .working, .waiting, .compacting]

        for state in activeStates {
            let opacities = CardLayerOpacityPolicy.opacities(for: state)
            let anyVisible = opacities.readyAmbient > 0
                || opacities.readyBorder > 0
                || opacities.waitingAmbient > 0
                || opacities.waitingBorder > 0
                || opacities.workingStripe > 0
                || opacities.workingBorder > 0

            XCTAssertTrue(anyVisible, "\(state) has no visible glow layers — cards would look idle")
        }
    }

    // MARK: - StatusChipsRow Presentation

    /// Session state with no delegation or run state should always produce .session presentation.
    func testStatusChipsPresentationDefaultsToSession() {
        let allStates: [SessionState?] = [.idle, .ready, .working, .waiting, .compacting, nil]

        for state in allStates {
            let sessionState = state.map { Self.makeSessionState($0) }
            let presentation = StatusChipsRow.presentation(
                sessionState: sessionState,
                delegationState: nil,
                activeRunState: nil,
            )
            XCTAssertEqual(presentation, .session(state), "State \(String(describing: state)) should produce .session")
        }
    }

    /// Delegation review_needed with a current review should produce .delegationReview.
    func testStatusChipsPresentationShowsDelegationReview() {
        let delegation = Self.makeDelegation(
            status: "review_needed",
            currentReview: RuntimeDelegationReview(
                milestoneId: "m1",
                briefPath: "/tmp/brief",
                manifestPath: "/tmp/manifest",
                requestedAt: "2025-01-01T00:00:00Z",
            ),
        )
        let presentation = StatusChipsRow.presentation(
            sessionState: nil,
            delegationState: delegation,
            activeRunState: nil,
        )
        XCTAssertEqual(presentation, .delegationReview)
    }

    /// Delegation resume_pending should produce .delegationResuming.
    func testStatusChipsPresentationShowsDelegationResuming() {
        let delegation = Self.makeDelegation(status: "resume_pending", currentReview: nil)
        let presentation = StatusChipsRow.presentation(
            sessionState: nil,
            delegationState: delegation,
            activeRunState: nil,
        )
        XCTAssertEqual(presentation, .delegationResuming)
    }

    /// Delegation resume_failed should produce .delegationResumeFailed.
    func testStatusChipsPresentationShowsDelegationResumeFailed() {
        let delegation = Self.makeDelegation(status: "resume_failed", currentReview: nil)
        let presentation = StatusChipsRow.presentation(
            sessionState: nil,
            delegationState: delegation,
            activeRunState: nil,
        )
        XCTAssertEqual(presentation, .delegationResumeFailed)
    }

    // MARK: - Test Helpers

    private static func makeSessionState(_ state: SessionState) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: nil,
            updatedAt: nil,
            sessionId: nil,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: true,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
        )
    }

    private static func makeDelegation(
        status: String,
        currentReview: RuntimeDelegationReview?,
    ) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: "/tmp/project",
            workerId: "w1",
            ideaId: nil,
            worktreeName: "wt",
            worktreePath: "/tmp/wt",
            sessionId: nil,
            status: try! DelegationStatus.decode(wire: status),
            startedAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
            submittedMilestoneId: nil,
            currentReview: currentReview,
        )
    }

    // MARK: - Animation Effect Gating

    /// Hovered cards must animate even if they are idle — hover effects need TimelineView.
    func testHoveredIdleCardAnimates() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: true,
            isWaiting: false,
            isWorking: false,
        )
        XCTAssertTrue(shouldAnimate, "Hovered idle cards need animation for hover effects")
    }

    /// Active + idle cards must animate for the active ring.
    func testActiveIdleCardAnimates() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: true,
            isHovered: false,
            isWaiting: false,
            isWorking: false,
        )
        XCTAssertTrue(shouldAnimate, "Active idle cards need animation for the active ring")
    }

    /// The animation policy should be symmetric: waiting OR working is enough to animate.
    func testWaitingAndWorkingBothTriggerAnimation() {
        let waitingOnly = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false, isHovered: false, isWaiting: true, isWorking: false,
        )
        let workingOnly = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false, isHovered: false, isWaiting: false, isWorking: true,
        )
        let both = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false, isHovered: false, isWaiting: true, isWorking: true,
        )

        XCTAssertTrue(waitingOnly)
        XCTAssertTrue(workingOnly)
        XCTAssertTrue(both)
    }
}
