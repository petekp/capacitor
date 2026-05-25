@testable import Capacitor
import XCTest

final class CircuitReceiptGoalPacketMethodTests: XCTestCase {
    func testAppendsOrdinaryReceiptGoalPacketMethodToBuiltinMethods() throws {
        let existing = [
            MethodTemplate(
                id: "execution_only",
                name: "Execute",
                description: "Direct implementation.",
                taskArchetype: "implementation",
                defaultInvolvement: .supervised,
                phases: [],
            ),
        ]

        let methods = CircuitReceiptGoalPacketMethod.includingReceiptGoalPacket(existing)

        XCTAssertEqual(methods.map(\.id), [
            "execution_only",
            CircuitReceiptGoalPacketMethod.id,
        ])
        XCTAssertEqual(methods.last?.name, "Claude Receipt Goal Packet")
        XCTAssertEqual(
            methods.last?.description,
            "Start a bounded Claude Code run from this idea and capture a receipt.",
        )
        XCTAssertTrue(try CircuitReceiptGoalPacketMethod.isReceiptGoalPacket(XCTUnwrap(methods.last)))
    }

    func testDoesNotDuplicateReceiptGoalPacketMethod() {
        let methods = CircuitReceiptGoalPacketMethod.includingReceiptGoalPacket([
            CircuitReceiptGoalPacketMethod.template,
        ])

        XCTAssertEqual(methods.map(\.id), [CircuitReceiptGoalPacketMethod.id])
    }
}
