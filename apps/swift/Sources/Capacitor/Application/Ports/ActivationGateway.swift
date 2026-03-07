import Foundation

protocol ActivationGateway {
    func activate(_ request: ShellActivationRequest) async throws -> ShellActivationDecision
}
