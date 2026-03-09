import Foundation

struct RuntimeStatus: Equatable {
    let isEnabled: Bool
    let isHealthy: Bool
    let message: String
    let pid: Int?
    let version: String?
}
