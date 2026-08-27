#if os(iOS)
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if appState.isAuthorized {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text("Signed In")
                                    .font(.headline)
                                Text("Telegram")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Not signed in")
                            .foregroundStyle(.secondary)
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
            }
            .navigationTitle("Settings")
        }
    }
}
#endif
