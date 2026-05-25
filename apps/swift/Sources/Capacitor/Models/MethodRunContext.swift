import Foundation

struct MethodRunContext: Equatable {
    let title: String?
    let description: String?
    let intent: String?
    let successCriteria: String?

    var jsonObject: [String: Any] {
        [
            "version": 1,
            "title": title ?? "",
            "description": description ?? "",
            "intent": intent ?? "",
            "success_criteria": successCriteria ?? "",
        ]
    }
}
