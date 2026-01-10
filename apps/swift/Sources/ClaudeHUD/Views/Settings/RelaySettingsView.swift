import SwiftUI
import AVFoundation
import Vision

struct RelaySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingScanner = false
    @State private var scanError: String?
    @State private var isPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Remote Sync")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                if appState.relayClient.isConfigured {
                    Circle()
                        .fill(appState.relayClient.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(appState.relayClient.isConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            if appState.relayClient.isConfigured {
                configuredView
            } else {
                unconfiguredView
            }

            if let error = scanError ?? appState.relayClient.connectionError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
        .sheet(isPresented: $showingScanner) {
            QRScannerView { result in
                handleScanResult(result)
            }
        }
    }

    private var configuredView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receive real-time updates from your desktop Claude Code sessions on this device.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                if appState.isRemoteMode {
                    Button("Disconnect") {
                        appState.disconnectRelay()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Connect") {
                        appState.connectRelay()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                Button("Re-pair") {
                    showingScanner = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a desktop computer to see Claude Code session states remotely.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))

            Button {
                showingScanner = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Scan Pairing Code")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func handleScanResult(_ result: Result<RelayConfig, Error>) {
        showingScanner = false
        isPairing = true

        switch result {
        case .success(let config):
            saveConfig(config)
            scanError = nil
            appState.connectRelay()

        case .failure(let error):
            scanError = error.localizedDescription
        }

        isPairing = false
    }

    private func saveConfig(_ config: RelayConfig) {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("hud-relay.json")

        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: configPath)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configPath.path
            )
        } catch {
            scanError = "Failed to save config: \(error.localizedDescription)"
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(configuration.isPressed ? 0.6 : 0.8))
            .cornerRadius(6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.05))
            .cornerRadius(6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct QRScannerView: View {
    let onScan: (Result<RelayConfig, Error>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasCameraPermission = false
    @State private var manualInput = ""
    @State private var showManualEntry = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if showManualEntry {
                    manualEntryView
                } else {
                    #if os(macOS)
                    macOSInstructions
                    #else
                    if hasCameraPermission {
                        CameraPreviewView(onDetected: handleDetection)
                    } else {
                        cameraPermissionView
                    }
                    #endif
                }

                Button("Enter Manually") {
                    showManualEntry.toggle()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding()
            .navigationTitle("Pair Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            checkCameraPermission()
        }
    }

    private var macOSInstructions: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.4))

            Text("On your desktop, run:")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))

            Text("./apps/relay/scripts/pair-device.sh")
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)

            Text("Then paste the pairing data below")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private var manualEntryView: some View {
        VStack(spacing: 12) {
            Text("Paste the pairing JSON from your desktop")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))

            TextEditor(text: $manualInput)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 100)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.3))
                .cornerRadius(6)

            Button("Pair") {
                parseManualInput()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(manualInput.isEmpty)
        }
    }

    private var cameraPermissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.4))

            Text("Camera access is required to scan QR codes")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))

            Button("Open Settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #elseif os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasCameraPermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    hasCameraPermission = granted
                }
            }
        default:
            hasCameraPermission = false
        }
    }

    private func handleDetection(_ code: String) {
        parseQRCode(code)
    }

    private func parseManualInput() {
        parseQRCode(manualInput)
    }

    private func parseQRCode(_ code: String) {
        guard let data = code.data(using: .utf8) else {
            onScan(.failure(PairingError.invalidData))
            return
        }

        do {
            let config = try JSONDecoder().decode(RelayConfig.self, from: data)

            guard !config.deviceId.isEmpty,
                  !config.secretKey.isEmpty,
                  !config.relayUrl.isEmpty else {
                onScan(.failure(PairingError.missingFields))
                return
            }

            onScan(.success(config))
        } catch {
            onScan(.failure(PairingError.parseError(error.localizedDescription)))
        }
    }
}

enum PairingError: LocalizedError {
    case invalidData
    case missingFields
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid QR code data"
        case .missingFields:
            return "Pairing data is missing required fields"
        case .parseError(let message):
            return "Failed to parse: \(message)"
        }
    }
}

#if os(iOS)
struct CameraPreviewView: UIViewRepresentable {
    let onDetected: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#else
struct CameraPreviewView: NSViewRepresentable {
    let onDetected: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
