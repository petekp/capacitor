import XCTest

struct LabeledExpectationScenario<Input, Expected> {
    let label: String
    let input: Input
    let expected: Expected
}

extension XCTestCase {
    func assertLabeledScenarios<Input, Expected: Equatable>(
        _ scenarios: [LabeledExpectationScenario<Input, Expected>],
        mismatch: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        evaluate: (Input) -> Expected
    ) {
        for scenario in scenarios {
            XCTAssertEqual(
                evaluate(scenario.input),
                scenario.expected,
                "[\(scenario.label)] \(mismatch)",
                file: file,
                line: line,
            )
        }
    }
}
