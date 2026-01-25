@testable import Capacitor
import Foundation
import XCTest

final class ProjectCardAnimationPolicyTests: XCTestCase {
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
}
