import SwiftUI

struct GSDCloudConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("GSD Cloud account") {
                    if session.isSignedIn {
                        LabeledContent("Account", value: session.email ?? String(localized: "Signed in"))
                        Button("Sync now") { Task { await session.syncNow() } }
                    } else {
                        Button("Sign in or create an account") { showSignIn = true }
                    }
                    Text("Use the same account in ChatGPT and on every device. ChatGPT can manage your cloud tasks while this app is closed.")
                }
                Section("Connect ChatGPT to your tasks") {
                    Link("Open GSD Tasks in ChatGPT", destination: URL(string: "https://chatgpt.com/plugins/plugins_6b0396bab7888191a5a7386c54a8475f")!)
                    Text("Choose Connect in the GSD Tasks plugin, then sign in with your GSD email and password on the GSD account page.")
                    Text("The plugin works with your cloud tasks. Continue with ChatGPT in Hanlin model settings controls which account pays for AI requests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ChatGPT and GSD Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showSignIn) { CloudAccountSignInView().environment(session) }
        }
    }
}
