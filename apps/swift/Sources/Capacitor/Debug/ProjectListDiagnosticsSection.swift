import SwiftUI

#if DEBUG
    struct ProjectListDiagnosticsSection: View {
        @AppStorage("debugShowProjectListDiagnostics") private var debugShowProjectListDiagnostics = true

        var body: some View {
            if debugShowProjectListDiagnostics {
                VStack(spacing: 6) {
                    DebugActiveStateCard()
                    DebugActivationTraceCard()
                }
            }
        }
    }
#else
    struct ProjectListDiagnosticsSection: View {
        var body: some View {
            EmptyView()
        }
    }
#endif
