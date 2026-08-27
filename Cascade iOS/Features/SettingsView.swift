#if os(iOS)
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            List {
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

                Section("Vault") {
                    if let error = appState.databaseError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if appState.isAuthorized {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not connected", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0 (iOS)")
                            .foregroundStyle(.secondary)
                    }
                }

                if appState.isAuthorized {
                    Section {
                        Button("Sign Out", role: .destructive) {
                            appState.logout()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
#endif
