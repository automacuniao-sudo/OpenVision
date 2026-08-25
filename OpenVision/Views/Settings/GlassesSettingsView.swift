// OpenVision - GlassesSettingsView.swift
// Meta Ray-Ban glasses registration and status

import SwiftUI

struct GlassesSettingsView: View {
    @EnvironmentObject var glassesManager: GlassesManager

    @State private var isRegistering: Bool = false
    @State private var errorMessage: String?
    @State private var showingUnregisterConfirmation: Bool = false

    var body: some View {
        Form {
            Section {
                if glassesManager.isRegistered {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Registered")
                            .foregroundColor(.green)
                        Spacer()
                        Button("Unregister") {
                            showingUnregisterConfirmation = true
                        }
                        .foregroundColor(.red)
                        .font(.caption)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Register with Meta AI app to access your glasses")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button {
                            register()
                        } label: {
                            HStack {
                                Spacer()
                                if isRegistering {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Opening Meta AI...")
                                } else {
                                    Image(systemName: "person.badge.plus")
                                    Text("Register App")
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRegistering)
                    }
                }

                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } header: {
                Text("Registration")
            } footer: {
                Text("Registration opens the Meta AI app where you'll grant OpenVision access to your glasses.")
            }

            if glassesManager.isRegistered {
                Section {
                    HStack {
                        Text("Connected Devices")
                        Spacer()
                        Text("\(glassesManager.connectedDeviceCount)")
                            .foregroundColor(.secondary)
                    }

                    if let device = glassesManager.connectedDevice {
                        HStack {
                            Text("Active Device")
                            Spacer()
                            Text(device)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Streaming")
                        Spacer()
                        if glassesManager.isStreaming {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                Text("Active")
                                    .foregroundColor(.red)
                            }
                        } else {
                            Text("Inactive")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Device Status")
                }

                Section {
                    Button {
                        Task {
                            await glassesManager.startStreaming()
                        }
                    } label: {
                        Label("Start Camera Stream", systemImage: "video")
                    }
                    .disabled(glassesManager.isStreaming)

                    Button {
                        Task {
                            await glassesManager.installOrUpdateGlassesApp()
                        }
                    } label: {
                        Label("Install/Update Glasses App", systemImage: "arrow.down.circle")
                    }

                    Button {
                        Task {
                            await glassesManager.stopStreaming()
                        }
                    } label: {
                        Label("Stop Camera Stream", systemImage: "video.slash")
                    }
                    .disabled(!glassesManager.isStreaming)

                    Button {
                        Task {
                            await glassesManager.capturePhoto()
                        }
                    } label: {
                        Label("Capture Photo", systemImage: "camera")
                    }
                    .disabled(!glassesManager.isStreaming)
                } header: {
                    Text("Camera Controls")
                } footer: {
                    Text("If registration succeeds but a camera session reports Device unavailable, use Install/Update Glasses App and try again.")
                }
            }

            Section {
                Link(destination: URL(string: "https://developer.meta.com/docs/wearables")!) {
                    HStack {
                        Text("Meta Wearables Documentation")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    TroubleshootingView()
                } label: {
                    Text("Troubleshooting")
                }
            } header: {
                Text("Help")
            }
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Unregister Glasses",
            isPresented: $showingUnregisterConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unregister", role: .destructive) {
                Task {
                    await glassesManager.unregister()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disconnect your glasses from OpenVision. You'll need to re-register to use them again.")
        }
        .alert("Error", isPresented: .constant(glassesManager.errorMessage != nil)) {
            Button("OK") {
                glassesManager.errorMessage = nil
            }
        } message: {
            if let error = glassesManager.errorMessage {
                Text(error)
            }
        }
    }

    private func register() {
        isRegistering = true
        errorMessage = nil

        Task {
            do {
                try await glassesManager.register()
                await MainActor.run {
                    isRegistering = false
                }
            } catch {
                await MainActor.run {
                    isRegistering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Troubleshooting View

struct TroubleshootingView: View {
    var body: some View {
        List {
            Section("Registration Issues") {
                TroubleshootingItem(
                    title: "Meta AI app not opening",
                    solution: "Make sure Meta AI app is installed and you're signed in."
                )
                TroubleshootingItem(
                    title: "Registration fails",
                    solution: "Enable Developer Mode in Meta AI app settings, then try again."
                )
                TroubleshootingItem(
                    title: "App not appearing in Meta AI",
                    solution: "Check that your Meta App ID and Client Token are correctly configured."
                )
            }

            Section("Connection Issues") {
                TroubleshootingItem(
                    title: "No devices found",
                    solution: "Ensure the glasses are paired in Meta AI/Bluetooth. Newer frames also require a recent DAT SDK."
                )
                TroubleshootingItem(
                    title: "Device unavailable",
                    solution: "Use Install/Update Glasses App, then retry. Also verify Camera permission and Team ID in Meta Wearables Developer Center."
                )
                TroubleshootingItem(
                    title: "Streaming not starting",
                    solution: "Close other apps using the glasses camera and retry. Diagnostics now record DeviceSession state and Meta DAT SDK logs."
                )
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TroubleshootingItem: View {
    let title: String
    let solution: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(solution)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        GlassesSettingsView()
            .environmentObject(GlassesManager.shared)
    }
}
