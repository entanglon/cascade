#if os(iOS)
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showClearCacheAlert = false
    @State private var cacheSize: Int64 = 0
    @State private var biometricEnabled: Bool = BiometricUnlock.isEnabled

    var body: some View {
        NavigationStack {
            List {
                // Profile section
                Section {
                    HStack(spacing: 14) {
                        if let photoData = appState.profilePhotoData,
                           let uiImage = UIImage(data: photoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            if let identity = appState.identity {
                                Text("\(identity.firstName) \(identity.lastName)".trimmingCharacters(in: .whitespaces))
                                    .font(.headline)
                                Text(identity.phone)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else if appState.isAuthorized {
                                Text("Signed In")
                                    .font(.headline)
                                Text("Telegram")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not Signed In")
                                    .font(.headline)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Vault section
                Section("Vault") {
                    HStack {
                        Label("Status", systemImage: "lock.shield")
                        Spacer()
                        if let error = appState.databaseError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.trailing)
                        } else if appState.isVaultConnected {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Connected")
                                    .foregroundStyle(.green)
                            }
                        } else if appState.isAuthorized {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Setting up…")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text("Not Connected")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if appState.isVaultConnected {
                        NavigationLink {
                            FileBrowserView()
                                .navigationTitle("Cascade Vault")
                        } label: {
                            Label("Browse Vault", systemImage: "folder")
                        }
                    }
                }

                // Security section
                Section("Security") {
                    HStack {
                        Label("Vault Key", systemImage: "key.fill")
                        Spacer()
                        if appState.isVaultLocked {
                            Button("Unlock with PIN") {
                                appState.showVaultUnlockSheet = true
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                        } else {
                            Text("Unlocked")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }

                    if BiometricUnlock.isAvailable() {
                        Toggle(isOn: Binding(
                            get: { biometricEnabled },
                            set: { newValue in
                                biometricEnabled = newValue
                                BiometricUnlock.setEnabled(newValue)
                            }
                        )) {
                            Label("Unlock with \(BiometricUnlock.biometryName)", systemImage: BiometricUnlock.biometryName == "Face ID" ? "faceid" : "touchid")
                        }
                    }
                }

                // Storage & Cache section
                Section("Storage & Cache") {
                    HStack {
                        Label("Local Cache", systemImage: "internaldrive")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                }

                // About section
                Section("About") {
                    HStack(spacing: 14) {
                        Image("CascadeLogo")
                            .resizable()
                            .renderingMode(.original)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cascade")
                                .font(.headline)
                            Text("Version 1.0 (iOS)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    HStack {
                        Text("Total Files")
                        Spacer()
                        Text("\(appState.allFiles.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                // Account section
                if appState.isAuthorized {
                    Section {
                        Button("Sign Out", role: .destructive) {
                            appState.logout()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                updateCacheSize()
            }
            .alert("Clear Local Cache?", isPresented: $showClearCacheAlert) {
                Button("Clear", role: .destructive) {
                    appState.clearLocalCache()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        updateCacheSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove downloaded files and cached thumbnails from your device. Your cloud files will not be affected.")
            }
        }
    }

    private func updateCacheSize() {
        cacheSize = appState.calculateCacheSize()
    }
}
#endif
