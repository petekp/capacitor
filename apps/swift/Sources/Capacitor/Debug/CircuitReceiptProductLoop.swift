import Foundation

struct CircuitContractProject: Codable, Equatable {
    let name: String
    let path: String
}

struct CircuitContractIdea: Codable, Equatable {
    let kind: String
    let id: String
    let project: CircuitContractProject
    let text: String
    let capturedAt: String

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case project
        case text
        case capturedAt = "captured_at"
    }
}

struct CircuitPlanningRequest: Codable, Equatable {
    let kind: String
    let targetAgent: String
    let idea: CircuitContractIdea

    enum CodingKeys: String, CodingKey {
        case kind
        case targetAgent = "target_agent"
        case idea
    }
}

struct CircuitPlanningResponse: Codable, Equatable {
    let kind: String
    let planning: Planning
    let pursuitProposal: CircuitPursuitProposal
    let goalPacket: ReceiptFirstProofGoalPacket

    struct Planning: Codable, Equatable {
        let mode: String
        let circuitRuntimeInvoked: Bool

        enum CodingKeys: String, CodingKey {
            case mode
            case circuitRuntimeInvoked = "circuit_runtime_invoked"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case planning
        case pursuitProposal = "pursuit_proposal"
        case goalPacket = "goal_packet"
    }
}

struct CircuitPursuitProposal: Codable, Equatable {
    let kind: String
    let id: String
    let ideaID: String
    let goal: String
    let whyNow: String
    let dependencies: [String]
    let risks: [String]
    let suggestedAgent: String
    let checkpointCondition: String
    let deliveryTarget: String

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case ideaID = "idea_id"
        case goal
        case whyNow = "why_now"
        case dependencies
        case risks
        case suggestedAgent = "suggested_agent"
        case checkpointCondition = "checkpoint_condition"
        case deliveryTarget = "delivery_target"
    }
}

struct CircuitReceiptProductLoopResult: Equatable {
    let idea: CircuitContractIdea
    let planningResponse: CircuitPlanningResponse
    let launchResult: ReceiptFirstProofLaunchResult
    let agentEvent: ReceiptProofAgentEvent
    let projection: ReceiptProofRenderingProjection
}

enum CircuitReceiptProductLoopError: Error, Equatable, LocalizedError {
    case missingCapturedIdea
    case processFailed(command: String, output: String?)
    case missingProcessOutput(command: String)
    case invalidPlanningResponse(String)
    case invalidAdapterResult(String)

    var errorDescription: String? {
        switch self {
        case .missingCapturedIdea:
            "Capture one receipt-first idea for the active project before running the Circuit loop."
        case let .processFailed(command, output):
            "Circuit protocol process failed: \(command). \(output ?? "No output.")"
        case let .missingProcessOutput(command):
            "Circuit protocol process returned no JSON output: \(command)."
        case let .invalidPlanningResponse(message):
            "Circuit planning response is invalid: \(message)"
        case let .invalidAdapterResult(message):
            "Circuit adapter result is invalid: \(message)"
        }
    }
}

enum CircuitCapturedIdeaMapper {
    static func map(idea: Idea, project: Project) -> CircuitContractIdea {
        let id = idea.id.hasPrefix("idea-") ? idea.id : "idea-\(idea.id)"
        let body = [idea.title, idea.description]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return CircuitContractIdea(
            kind: "idea",
            id: id,
            project: CircuitContractProject(name: project.name, path: project.path),
            text: body.isEmpty ? idea.title : body,
            capturedAt: idea.added,
        )
    }
}

struct CircuitReceiptProductLoopPaths {
    let root: URL
    let proofDirectory: URL
    let planningDirectory: URL
    let nativeSessionDirectory: URL
    let normalizationDirectory: URL

    init(
        capacitorRoot: URL = ReceiptFirstProofArtifacts.defaultCapacitorRoot(),
        proofDirectoryName: String = "receipt-first-product-loop",
    ) {
        root = capacitorRoot
        proofDirectory = capacitorRoot.appendingPathComponent("docs/circuit/proofs/\(proofDirectoryName)")
        planningDirectory = proofDirectory.appendingPathComponent("planning", isDirectory: true)
        nativeSessionDirectory = proofDirectory.appendingPathComponent("native-session", isDirectory: true)
        normalizationDirectory = proofDirectory.appendingPathComponent("normalization", isDirectory: true)
    }

    var sourceIdeaURL: URL {
        planningDirectory.appendingPathComponent("01-capacitor-idea-source.json")
    }

    var contractIdeaURL: URL {
        planningDirectory.appendingPathComponent("02-contract-idea.json")
    }

    var planningRequestURL: URL {
        planningDirectory.appendingPathComponent("03-planning-request.json")
    }

    var planningResponseURL: URL {
        planningDirectory.appendingPathComponent("04-planning-response.json")
    }

    var goalPacketURL: URL {
        planningDirectory.appendingPathComponent("05-goal-packet.json")
    }

    var agentEventURL: URL {
        normalizationDirectory.appendingPathComponent("01-agent-event.json")
    }

    var normalizationRequestURL: URL {
        normalizationDirectory.appendingPathComponent("00-normalization-request.json")
    }
}

struct CircuitProtocolProcessBoundary {
    typealias RunShell = (String) async -> (exitCode: Int32, output: String?)

    let paths: CircuitReceiptProductLoopPaths
    var runShell: RunShell = { script in
        await TerminalLauncher.runBashScriptWithResult(script)
    }

    var fileManager: FileManager = .default

    func plan(_ request: CircuitPlanningRequest) async throws -> CircuitPlanningResponse {
        try writeJSON(request, to: paths.planningRequestURL)
        let command = "cd \(shellEscape(paths.root.path)) && python3 scripts/circuit/plan-goal-packet.py --stdin < \(shellEscape(paths.planningRequestURL.path))"
        let result = await runShell(command)
        guard result.exitCode == 0 else {
            throw CircuitReceiptProductLoopError.processFailed(command: command, output: result.output)
        }
        guard let output = result.output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CircuitReceiptProductLoopError.missingProcessOutput(command: command)
        }

        let data = Data(output.utf8)
        let response = try JSONDecoder().decode(CircuitPlanningResponse.self, from: data)
        guard response.kind == "plan_goal_packet_response" else {
            throw CircuitReceiptProductLoopError.invalidPlanningResponse("Expected kind=plan_goal_packet_response.")
        }
        guard response.planning.mode == "headless_receipt_first_planner",
              response.planning.circuitRuntimeInvoked == false
        else {
            throw CircuitReceiptProductLoopError.invalidPlanningResponse("Planning must be headless and no-runtime.")
        }
        guard response.goalPacket.targetAgent == request.targetAgent,
              response.goalPacket.expectedReturn == "receipt",
              response.goalPacket.body.contains("CIRCUIT_RECEIPT")
        else {
            throw CircuitReceiptProductLoopError.invalidPlanningResponse("GoalPacket does not match receipt-first Claude Code boundary.")
        }

        try writeJSON(response, to: paths.planningResponseURL)
        try writeJSON(response.goalPacket, to: paths.goalPacketURL)
        return response
    }

    func normalize(
        rawReceiptURL: URL,
        adapterResultURL: URL,
        outputURL: URL,
    ) async throws -> ReceiptProofAgentEvent {
        let rawReceiptText = try String(contentsOf: rawReceiptURL, encoding: .utf8)
        let adapterResultData = try Data(contentsOf: adapterResultURL)
        let adapterResult = try JSONSerialization.jsonObject(with: adapterResultData)
        guard let adapterResultObject = adapterResult as? [String: Any] else {
            throw CircuitReceiptProductLoopError.invalidAdapterResult("Expected adapter result JSON object.")
        }
        let normalizationRequest: [String: Any] = [
            "kind": "normalize_agent_event_request",
            "raw_receipt_text": rawReceiptText,
            "adapter_result": adapterResultObject,
            "source_raw_receipt_path": rawReceiptURL.path,
        ]
        let normalizationRequestData = try JSONSerialization.data(
            withJSONObject: normalizationRequest,
            options: [.prettyPrinted, .sortedKeys],
        )
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try normalizationRequestData.write(to: paths.normalizationRequestURL, options: .atomic)

        let command = "cd \(shellEscape(paths.root.path)) && python3 scripts/circuit/normalize-agent-event.py --stdin < \(shellEscape(paths.normalizationRequestURL.path))"
        let result = await runShell(command)
        guard result.exitCode == 0 else {
            throw CircuitReceiptProductLoopError.processFailed(command: command, output: result.output)
        }
        guard let output = result.output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CircuitReceiptProductLoopError.missingProcessOutput(command: command)
        }

        try Data(output.utf8).write(to: outputURL, options: .atomic)
        return try JSONDecoder().decode(ReceiptProofAgentEvent.self, from: Data(output.utf8))
    }

    func writeSourceIdea(_ idea: Idea, project: Project, contractIdea: CircuitContractIdea) throws {
        let source: [String: String] = [
            "kind": "capacitor_captured_idea",
            "id": idea.id,
            "title": idea.title,
            "description": idea.description,
            "captured_at": idea.added,
            "project_name": project.name,
            "project_path": project.path,
        ]
        try writeJSONObject(source, to: paths.sourceIdeaURL)
        try writeJSON(contractIdea, to: paths.contractIdeaURL)
    }

    private func writeJSON(_ value: some Encodable, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func writeJSONObject(_ value: [String: String], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

struct CircuitReceiptProductLoop {
    let paths: CircuitReceiptProductLoopPaths
    let boundary: CircuitProtocolProcessBoundary
    let adapter: ReceiptFirstProofAdapter

    init(
        paths: CircuitReceiptProductLoopPaths = CircuitReceiptProductLoopPaths(),
        boundary: CircuitProtocolProcessBoundary? = nil,
        adapter: ReceiptFirstProofAdapter = ReceiptFirstProofAdapter(),
    ) {
        self.paths = paths
        self.boundary = boundary ?? CircuitProtocolProcessBoundary(paths: paths)
        self.adapter = adapter
    }

    func run(project: Project, idea: Idea) async throws -> CircuitReceiptProductLoopResult {
        let contractIdea = CircuitCapturedIdeaMapper.map(idea: idea, project: project)
        try boundary.writeSourceIdea(idea, project: project, contractIdea: contractIdea)

        let planningRequest = CircuitPlanningRequest(
            kind: "plan_goal_packet_request",
            targetAgent: "claude_code",
            idea: contractIdea,
        )
        let planningResponse = try await boundary.plan(planningRequest)
        let launchResult = try await adapter.launchAndWaitForCapture(
            packet: planningResponse.goalPacket,
            proofDirectoryURL: paths.nativeSessionDirectory,
        )
        let agentEvent = try await boundary.normalize(
            rawReceiptURL: launchResult.launch.artifacts.rawReceiptURL,
            adapterResultURL: launchResult.launch.artifacts.resultURL,
            outputURL: paths.agentEventURL,
        )
        let projection = try ReceiptProofRenderingStore(
            resultURL: launchResult.launch.artifacts.resultURL,
            agentEventURL: paths.agentEventURL,
        ).loadProjection()
        return CircuitReceiptProductLoopResult(
            idea: contractIdea,
            planningResponse: planningResponse,
            launchResult: launchResult,
            agentEvent: agentEvent,
            projection: projection,
        )
    }
}
