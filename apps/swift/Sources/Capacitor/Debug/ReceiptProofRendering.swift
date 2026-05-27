import Foundation
import SwiftUI

struct ReceiptProofAdapterResult: Codable, Equatable {
    let kind: String
    let status: String
    let finishedAt: String
    let goalPacketID: String
    let bodySHA256: String
    let codexExitCode: Int
    var agentExitCode: Int {
        codexExitCode
    }

    let visibleSurface: String
    let injection: Injection
    let capture: Capture
    let limits: [String]

    struct Injection: Codable, Equatable {
        let mode: String
        let bodyPath: String
        let exactBodyMatch: Bool

        enum CodingKeys: String, CodingKey {
            case mode
            case bodyPath = "body_path"
            case exactBodyMatch = "exact_body_match"
        }
    }

    struct Capture: Codable, Equatable {
        let mode: String
        let rawReceiptPath: String
        let preservedForNormalization: Bool

        enum CodingKeys: String, CodingKey {
            case mode
            case rawReceiptPath = "raw_receipt_path"
            case preservedForNormalization = "preserved_for_normalization"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case status
        case finishedAt = "finished_at"
        case goalPacketID = "goal_packet_id"
        case bodySHA256 = "body_sha256"
        case agentExitCode = "agent_exit_code"
        case codexExitCode = "codex_exit_code"
        case visibleSurface = "visible_surface"
        case injection
        case capture
        case limits
    }
}

extension ReceiptProofAdapterResult {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        status = try container.decode(String.self, forKey: .status)
        finishedAt = try container.decode(String.self, forKey: .finishedAt)
        goalPacketID = try container.decode(String.self, forKey: .goalPacketID)
        bodySHA256 = try container.decode(String.self, forKey: .bodySHA256)
        codexExitCode = try container.decodeIfPresent(Int.self, forKey: .agentExitCode)
            ?? container.decode(Int.self, forKey: .codexExitCode)
        visibleSurface = try container.decode(String.self, forKey: .visibleSurface)
        injection = try container.decode(Injection.self, forKey: .injection)
        capture = try container.decode(Capture.self, forKey: .capture)
        limits = try container.decode([String].self, forKey: .limits)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encode(goalPacketID, forKey: .goalPacketID)
        try container.encode(bodySHA256, forKey: .bodySHA256)
        try container.encode(agentExitCode, forKey: .agentExitCode)
        try container.encode(codexExitCode, forKey: .codexExitCode)
        try container.encode(visibleSurface, forKey: .visibleSurface)
        try container.encode(injection, forKey: .injection)
        try container.encode(capture, forKey: .capture)
        try container.encode(limits, forKey: .limits)
    }
}

struct ReceiptProofReceipt: Codable, Equatable {
    let kind: String
    let id: String
    let goalPacketID: String
    let status: String
    let summary: String
    let evidence: [String]
    let changedPaths: [String]
    let openRisks: [String]
    let nextAction: String

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case goalPacketID = "goal_packet_id"
        case status
        case summary
        case evidence
        case changedPaths = "changed_paths"
        case openRisks = "open_risks"
        case nextAction = "next_action"
    }
}

struct ReceiptProofAgentEvent: Codable, Equatable {
    let kind: String
    let id: String
    let goalPacketID: String
    let session: Session
    let type: String
    let payload: ReceiptProofReceipt
    let recordedAt: String
    let normalization: Normalization?

    struct Session: Codable, Equatable {
        let host: String
        let sessionID: String
        let visibleToOwner: Bool

        enum CodingKeys: String, CodingKey {
            case host
            case sessionID = "session_id"
            case visibleToOwner = "visible_to_owner"
        }
    }

    struct Normalization: Codable, Equatable {
        let mode: String
        let sourceRawReceiptPath: String
        let circuitRuntimeInvoked: Bool

        enum CodingKeys: String, CodingKey {
            case mode
            case sourceRawReceiptPath = "source_raw_receipt_path"
            case circuitRuntimeInvoked = "circuit_runtime_invoked"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case goalPacketID = "goal_packet_id"
        case session
        case type
        case payload
        case recordedAt = "recorded_at"
        case normalization
    }
}

struct OperatorEvidenceBriefProjection: Equatable {
    let goal: String
    let claim: String
    let evidence: [String]
    let risks: [String]
    let ask: String

    static func make(
        receipt: ReceiptProofReceipt,
        goalBody: String?,
    ) -> OperatorEvidenceBriefProjection {
        OperatorEvidenceBriefProjection(
            goal: extractedGoal(from: goalBody) ?? "Review receipt for \(receipt.goalPacketID)",
            claim: cleaned(receipt.summary) ?? "Receipt captured.",
            evidence: cleanedList(receipt.evidence, fallback: "No evidence reported."),
            risks: cleanedList(receipt.openRisks, fallback: "No open risks reported."),
            ask: cleaned(receipt.nextAction) ?? "Review the receipt and decide whether to continue.",
        )
    }

    private static func extractedGoal(from body: String?) -> String? {
        guard let body else { return nil }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("/goal ") {
                return cleaned(String(trimmed.dropFirst("/goal ".count)))
            }
            return cleaned(trimmed)
        }
        return nil
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func cleanedList(_ values: [String], fallback: String) -> [String] {
        let cleanedValues = values.compactMap(cleaned)
        return cleanedValues.isEmpty ? [fallback] : cleanedValues
    }
}

struct ReceiptProofRenderingProjection: Equatable {
    let state: String
    let primaryText: String
    let secondaryText: String
    let statusLabel: String
    let statusTintName: String
    let result: ReceiptProofAdapterResult
    let agentEvent: ReceiptProofAgentEvent
    let receipt: ReceiptProofReceipt
    let operatorBrief: OperatorEvidenceBriefProjection
    let resultPath: String
    let agentEventPath: String
    let sourceRawReceiptPath: String?

    var metadata: [(label: String, value: String)] {
        [
            ("Goal", result.goalPacketID),
            ("Event", agentEvent.id),
            ("Receipt", receipt.id),
            ("Adapter", result.status),
            ("Agent", receipt.status),
            ("Host", agentEvent.session.host),
            ("Exit", String(result.agentExitCode)),
            ("Recorded", agentEvent.recordedAt),
        ]
    }
}

enum ReceiptProofRenderingError: Error, Equatable, LocalizedError {
    case missingMarker
    case invalidMarker
    case mismatchedGoalPacket(result: String, event: String, receipt: String)
    case eventKindNotSupported(String)
    case eventTypeNotSupported(String)
    case resultNotNativeCapture(String)
    case receiptKindNotSupported(String)
    case normalizationModeNotSupported(String)
    case circuitRuntimeNormalizationNotSupported
    case missingSourceRawReceiptPath
    case missingSourceRawReceipt(String)
    case staleAgentEventPayload

    var errorDescription: String? {
        switch self {
        case .missingMarker:
            "Raw receipt is missing the CIRCUIT_RECEIPT marker."
        case .invalidMarker:
            "Raw receipt marker must be the first non-empty line."
        case let .mismatchedGoalPacket(result, event, receipt):
            "Goal packet mismatch: result=\(result), event=\(event), receipt=\(receipt)."
        case let .eventKindNotSupported(kind):
            "AgentEvent kind is not supported: \(kind)."
        case let .eventTypeNotSupported(type):
            "AgentEvent type is not supported: \(type)."
        case let .resultNotNativeCapture(status):
            "Adapter result is not a native capture result: \(status)."
        case let .receiptKindNotSupported(kind):
            "Receipt kind is not supported: \(kind)."
        case let .normalizationModeNotSupported(mode):
            "AgentEvent normalization mode is not supported: \(mode)."
        case .circuitRuntimeNormalizationNotSupported:
            "Circuit runtime normalization is not supported in this proof surface."
        case .missingSourceRawReceiptPath:
            "Normalized AgentEvent is missing its source raw receipt path."
        case let .missingSourceRawReceipt(path):
            "Normalized AgentEvent source raw receipt is missing: \(path)."
        case .staleAgentEventPayload:
            "Normalized AgentEvent payload does not match the source raw receipt."
        }
    }
}

struct ReceiptProofRenderingStore {
    let resultURL: URL
    let agentEventURL: URL
    var fileManager: FileManager = .default

    init(
        resultURL: URL = ReceiptProofRenderingStore.defaultResultURL(),
        agentEventURL: URL = ReceiptProofRenderingStore.defaultAgentEventURL(),
        fileManager: FileManager = .default,
    ) {
        self.resultURL = resultURL
        self.agentEventURL = agentEventURL
        self.fileManager = fileManager
    }

    static func defaultAdapterProofDirectoryURL(
        capacitorRoot: URL = ReceiptFirstProofArtifacts.defaultCapacitorRoot(),
    ) -> URL {
        capacitorRoot
            .appendingPathComponent("docs/circuit/proofs/receipt-first-product-loop/native-session")
    }

    static func defaultNormalizationProofDirectoryURL(
        capacitorRoot: URL = ReceiptFirstProofArtifacts.defaultCapacitorRoot(),
    ) -> URL {
        capacitorRoot
            .appendingPathComponent("docs/circuit/proofs/receipt-first-product-loop/normalization")
    }

    static func defaultResultURL(
        capacitorRoot: URL = ReceiptFirstProofArtifacts.defaultCapacitorRoot(),
    ) -> URL {
        defaultAdapterProofDirectoryURL(capacitorRoot: capacitorRoot)
            .appendingPathComponent("07-native-adapter-result.json")
    }

    static func defaultRawReceiptURL(
        capacitorRoot: URL = ReceiptFirstProofArtifacts.defaultCapacitorRoot(),
    ) -> URL {
        defaultAdapterProofDirectoryURL(capacitorRoot: capacitorRoot)
            .appendingPathComponent("06-native-captured-raw-receipt.txt")
    }

    static func defaultAgentEventURL(
        capacitorRoot: URL = ReceiptFirstProofArtifacts.defaultCapacitorRoot(),
    ) -> URL {
        defaultNormalizationProofDirectoryURL(capacitorRoot: capacitorRoot)
            .appendingPathComponent("01-agent-event.json")
    }

    func loadProjection() throws -> ReceiptProofRenderingProjection {
        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(ReceiptProofAdapterResult.self, from: resultData)

        let agentEventData = try Data(contentsOf: agentEventURL)
        let agentEvent = try JSONDecoder().decode(ReceiptProofAgentEvent.self, from: agentEventData)

        try Self.validateSourceRawReceiptIfPresent(
            agentEvent: agentEvent,
            fileManager: fileManager,
        )

        return try Self.makeProjection(
            result: result,
            agentEvent: agentEvent,
            goalBody: Self.optionalText(
                atPath: result.injection.bodyPath,
                fileManager: fileManager,
            ),
            resultPath: resultURL.path,
            agentEventPath: agentEventURL.path,
        )
    }

    static func receiptJSONData(fromRawReceipt rawReceipt: String) throws -> Data {
        let lines = rawReceipt.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstNonEmptyIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ReceiptProofRenderingError.missingMarker
        }

        guard lines[firstNonEmptyIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "CIRCUIT_RECEIPT" else {
            throw ReceiptProofRenderingError.invalidMarker
        }

        let jsonLines = lines.dropFirst(firstNonEmptyIndex + 1)
        let jsonString = jsonLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsonString.isEmpty else {
            throw ReceiptProofRenderingError.missingMarker
        }

        return Data(jsonString.utf8)
    }

    static func validateSourceRawReceiptIfPresent(
        agentEvent: ReceiptProofAgentEvent,
        fileManager: FileManager = .default,
    ) throws {
        guard let sourceRawReceiptPath = agentEvent.normalization?.sourceRawReceiptPath else {
            throw ReceiptProofRenderingError.missingSourceRawReceiptPath
        }
        guard agentEvent.normalization?.mode == "headless_receipt_normalizer" else {
            throw ReceiptProofRenderingError.normalizationModeNotSupported(agentEvent.normalization?.mode ?? "missing")
        }
        guard agentEvent.normalization?.circuitRuntimeInvoked == false else {
            throw ReceiptProofRenderingError.circuitRuntimeNormalizationNotSupported
        }

        guard fileManager.fileExists(atPath: sourceRawReceiptPath) else {
            throw ReceiptProofRenderingError.missingSourceRawReceipt(sourceRawReceiptPath)
        }

        let rawReceipt = try String(contentsOfFile: sourceRawReceiptPath, encoding: .utf8)
        let rawReceiptData = try receiptJSONData(fromRawReceipt: rawReceipt)
        let sourceReceipt = try JSONDecoder().decode(ReceiptProofReceipt.self, from: rawReceiptData)
        guard sourceReceipt == agentEvent.payload else {
            throw ReceiptProofRenderingError.staleAgentEventPayload
        }
    }

    static func makeProjection(
        result: ReceiptProofAdapterResult,
        agentEvent: ReceiptProofAgentEvent,
        goalBody: String? = nil,
        resultPath: String,
        agentEventPath: String,
    ) throws -> ReceiptProofRenderingProjection {
        guard result.kind == "native_receipt_first_proof_result" else {
            throw ReceiptProofRenderingError.resultNotNativeCapture(result.kind)
        }
        guard result.status == "native_capture_complete" || result.status == "native_capture_with_nonzero_exit" else {
            throw ReceiptProofRenderingError.resultNotNativeCapture(result.status)
        }
        guard agentEvent.kind == "agent_event" else {
            throw ReceiptProofRenderingError.eventKindNotSupported(agentEvent.kind)
        }
        guard agentEvent.type == "receipt" else {
            throw ReceiptProofRenderingError.eventTypeNotSupported(agentEvent.type)
        }
        let receipt = agentEvent.payload
        guard receipt.kind == "receipt" else {
            throw ReceiptProofRenderingError.receiptKindNotSupported(receipt.kind)
        }
        guard result.goalPacketID == agentEvent.goalPacketID,
              agentEvent.goalPacketID == receipt.goalPacketID
        else {
            throw ReceiptProofRenderingError.mismatchedGoalPacket(
                result: result.goalPacketID,
                event: agentEvent.goalPacketID,
                receipt: receipt.goalPacketID,
            )
        }

        let state: String
        let statusLabel: String
        let statusTintName: String

        switch receipt.status {
        case "completed":
            state = "complete"
            statusLabel = "Complete"
            statusTintName = "green"
        case "blocked":
            state = "blocked"
            statusLabel = "Blocked"
            statusTintName = "orange"
        case "failed":
            state = "failed"
            statusLabel = "Failed"
            statusTintName = "red"
        default:
            state = "blocked"
            statusLabel = receipt.status.capitalized
            statusTintName = "orange"
        }

        return ReceiptProofRenderingProjection(
            state: state,
            primaryText: "Receipt proof captured",
            secondaryText: receipt.summary,
            statusLabel: statusLabel,
            statusTintName: statusTintName,
            result: result,
            agentEvent: agentEvent,
            receipt: receipt,
            operatorBrief: OperatorEvidenceBriefProjection.make(
                receipt: receipt,
                goalBody: goalBody,
            ),
            resultPath: resultPath,
            agentEventPath: agentEventPath,
            sourceRawReceiptPath: agentEvent.normalization?.sourceRawReceiptPath,
        )
    }

    private static func optionalText(
        atPath path: String,
        fileManager: FileManager,
    ) -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}

struct ReceiptProofRenderingWindow: View {
    @State private var projection: ReceiptProofRenderingProjection?
    @State private var loadError: String?

    private let store: ReceiptProofRenderingStore

    init(store: ReceiptProofRenderingStore = ReceiptProofRenderingStore()) {
        self.store = store
    }

    var body: some View {
        Group {
            if let projection {
                content(for: projection)
            } else if let loadError {
                errorView(message: loadError)
            } else {
                loadingView
            }
        }
        .background {
            ZStack {
                DarkFrostedGlass()
                Color.black.opacity(0.16)
            }
            .ignoresSafeArea()
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.receiptProofRenderingIdentifier)
        .task {
            load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .circuitFirstSliceDidCapture)) { _ in
            load()
        }
    }

    private func content(for projection: ReceiptProofRenderingProjection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(for: projection)
                operatorBriefView(projection.operatorBrief)

                metadataGrid(for: projection)

                section("RAW RECEIPT DETAILS") {
                    VStack(alignment: .leading, spacing: 14) {
                        receiptDetail(label: "Summary", value: projection.secondaryText)

                        if !projection.receipt.evidence.isEmpty {
                            receiptDetailList(label: "Evidence", items: projection.receipt.evidence)
                        }

                        if !projection.receipt.openRisks.isEmpty {
                            receiptDetailList(label: "Receipt-reported risks", items: projection.receipt.openRisks)
                        }

                        receiptDetail(label: "Receipt next action", value: projection.receipt.nextAction)
                    }
                }

                section("ARTIFACTS") {
                    artifactRow(label: "Adapter result", path: projection.resultPath)
                    artifactRow(label: "Normalized AgentEvent", path: projection.agentEventPath)
                    if let sourceRawReceiptPath = projection.sourceRawReceiptPath {
                        artifactRow(label: "Source raw receipt", path: sourceRawReceiptPath)
                    }
                    artifactRow(label: "Inserted body", path: projection.result.injection.bodyPath)
                }

                section("BOUNDARY") {
                    bulletList([
                        "Circuit-style normalization is represented by one deterministic headless normalizer artifact.",
                        "Circuit runtime is not invoked.",
                    ] + projection.result.limits)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func operatorBriefView(_ brief: OperatorEvidenceBriefProjection) -> some View {
        section("OPERATOR BRIEF") {
            VStack(alignment: .leading, spacing: 14) {
                briefField(label: "Goal", value: brief.goal)
                briefField(label: "Claim", value: brief.claim)
                briefList(label: "Evidence", items: brief.evidence)
                briefList(label: "Risk", items: brief.risks)
                briefField(label: "Ask", value: brief.ask)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75),
                    ),
            )
        }
    }

    private func briefField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            briefLabel(label)
            Text(value)
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func briefList(label: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            briefLabel(label)
            bulletList(items)
        }
    }

    private func briefLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(AppTypography.caption.weight(.bold))
            .foregroundColor(.white.opacity(0.4))
    }

    private func header(for projection: ReceiptProofRenderingProjection) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: iconName(for: projection.state))
                .font(AppTypography.pageTitle)
                .foregroundColor(tint(for: projection))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Receipt Rendering")
                        .font(AppTypography.caption.weight(.bold))
                        .tracking(2)
                        .foregroundColor(.orange.opacity(0.86))

                    Text(projection.statusLabel)
                        .font(AppTypography.caption.weight(.semibold))
                        .foregroundColor(tint(for: projection))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(tint(for: projection).opacity(0.14)),
                        )
                }

                Text(projection.primaryText)
                    .font(AppTypography.pageTitle)
                    .foregroundColor(.white.opacity(0.94))

                Text("Capacitor is rendering a headless-normalized AgentEvent. Circuit runtime is not running here.")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer(minLength: 0)
        }
    }

    private func receiptDetail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(AppTypography.caption.weight(.bold))
                .foregroundColor(.white.opacity(0.34))
            Text(value)
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.72))
                .textSelection(.enabled)
        }
    }

    private func receiptDetailList(label: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(AppTypography.caption.weight(.bold))
                .foregroundColor(.white.opacity(0.34))
            bulletList(items)
        }
    }

    private func metadataGrid(for projection: ReceiptProofRenderingProjection) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .leading),
            ],
            alignment: .leading,
            spacing: 10,
        ) {
            ForEach(projection.metadata, id: \.label) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label.uppercased())
                        .font(AppTypography.caption.weight(.bold))
                        .foregroundColor(.white.opacity(0.35))
                    Text(item.value)
                        .font(AppTypography.monoCaption)
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5),
                        ),
                )
            }
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View,
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(title)
            content()
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color.white.opacity(0.34))
                        .frame(width: 4, height: 4)
                    Text(item)
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.white.opacity(0.74))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func artifactRow(label: String, path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.45))

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(AppTypography.bodySecondary.weight(.medium))
                    .foregroundColor(.white.opacity(0.88))
                Text(path)
                    .font(AppTypography.monoCaption)
                    .foregroundColor(.white.opacity(0.46))
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5),
                ),
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.orange.opacity(0.62))
                .frame(width: 4, height: 4)

            Text(title)
                .font(AppTypography.caption.weight(.bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.42))
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading receipt proof")
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Receipt proof unavailable")
                .font(AppTypography.sectionTitle)
                .foregroundColor(.white.opacity(0.9))
            Text(message)
                .font(AppTypography.body)
                .foregroundColor(.red.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(24)
    }

    private func load() {
        do {
            projection = try store.loadProjection()
            loadError = nil
        } catch {
            projection = nil
            loadError = error.localizedDescription
        }
    }

    private func tint(for projection: ReceiptProofRenderingProjection) -> Color {
        switch projection.statusTintName {
        case "green":
            .green
        case "red":
            .red
        default:
            .orange
        }
    }

    private func iconName(for state: String) -> String {
        switch state {
        case "complete":
            "checkmark.seal.fill"
        case "failed":
            "xmark.octagon.fill"
        default:
            "exclamationmark.triangle.fill"
        }
    }
}
