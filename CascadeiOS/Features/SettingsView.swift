#if os(iOS)
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("appearance") private var appearance = "dark"
    @State private var showClearCacheConfirm = false
    @State private var tdlibCacheSize: Int64?

    var body: some View {
        NavigationStack {
            List {
                // Account
                Section("Account") {
                    if let user = TelegramClient.shared.currentUser {
                        HStack(spacing: 12) {
                            if let photo = user.profilePhoto,
                               let data = try? Data(contentsOf: photo.local.imagePath),
                               let img = UIImage(data: data) {
                                Image(uiImage: img)
                                    .resizable()
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            VStack(alignment: .leading) {
                                Text(user.firstName + " " + user.lastName)
                                    .font(.headline)
                                Text("@\(user.username ?? "N/A")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("Log Out", role: .destructive) {
                        appState.logout()
                    }
                }

                // Security
                if BiometricUnlock.isAvailable() {
                    Section("Security") {
                        Toggle("Face ID / Touch ID Unlock", isOn: Binding(
                            get: { BiometricUnlock.isEnabled },
                            set: { BiometricUnlock.setEnabled($0) }
                        ))
                    }
                }

                // Playback
                Section("Playback") {
                    NavigationLink("Video Player") {
                        List {
                            Toggle("Hardware Decoding (VideoToolbox)", isOn: Binding(
                                get: { !UserDefaults.standard.bool(forKey: "mpvDisableHWDec") },
                                set: { UserDefaults.standard.set(!$0, forKey: "mpvDisableHWDec") }
                            ))
                        }
                        .navigationTitle("Video Player")
                    }
                }

                // Cache
                Section("Cache") {
                    if let size = tdlibCacheSize {
                        Text("TDLib cache: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear Local Cache", role: .destructive) {
                        showClearCacheConfirm = true
                    }
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .confirmationDialog(
            "Clear local cache? This deletes downloaded previews, thumbnails and Telegram's download store. Your files in Telegram are safe.",
            isPresented: $showClearCacheConfirm, titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) { appState.clearLocalCache() }
        }
        .task {
            tdlibCacheSize = await TelegramClient.shared.tdlibFilesSize()
        }
    }
}
#endif
