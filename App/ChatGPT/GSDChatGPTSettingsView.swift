import HanlinChatCore
import SwiftUI

@MainActor
struct GSDChatGPTSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var account: GSDChatGPTAccountState
    let cancelInference: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(account.status).accessibilityIdentifier("chatgpt.account.status")
                    if let email = account.email {
                        LabeledContent("ChatGPT account", value: email)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                } header: {
                    Text("Use your ChatGPT plan")
                } footer: {
                    Text("Eligible AI requests use your ChatGPT plan or credits. Your GSD Cloud account is a separate connection.")
                }

                if !account.accounts.isEmpty {
                    Section("Saved ChatGPT accounts") {
                        ForEach(account.accounts) { entry in
                            Button {
                                Task {
                                    await cancelInference()
                                    account.selectAccount(entry.id)
                                    await account.loadModels()
                                }
                            } label: {
                                HStack {
                                    Text(entry.label).lineLimit(2)
                                    Spacer()
                                    if account.activeID == entry.id {
                                        Image(systemName: "checkmark").accessibilityLabel("Selected")
                                    }
                                }
                            }
                            .disabled(account.isBusy)
                        }
                    }
                }

                Section {
                    if let id = account.activeID {
                        Button("Continue with ChatGPT") {
                            Task { await cancelInference(); await account.signIn(accountID: id) }
                        }
                        .accessibilityIdentifier("chatgpt.continue")
                        if !account.canUsePlan {
                            Button("Enable ChatGPT plan use") {
                                Task {
                                    await cancelInference()
                                    await account.signIn(accountID: id, requestPlanConsent: true)
                                }
                            }
                        }
                        Button("Use another ChatGPT account") {
                            Task { await cancelInference(); await account.signIn() }
                        }
                    } else {
                        Button("Continue with ChatGPT") {
                            Task { await cancelInference(); await account.signIn() }
                        }
                        .accessibilityIdentifier("chatgpt.continue")
                    }
                    if account.isBusy {
                        ProgressView("Connecting to ChatGPT…")
                    }
                }
                .disabled(account.isBusy)

                if account.canUsePlan {
                    Section("Available ChatGPT models") {
                        if account.models.isEmpty {
                            Button("Load ChatGPT models") { Task { await account.loadModels() } }
                        } else {
                            Picker("Model", selection: Binding(
                                get: { account.selectedModelID }, set: account.selectModel)) {
                                ForEach(account.models) { model in
                                    Text(model.displayName).tag(model.slug)
                                }
                            }
                        }
                        Text("Models and usage depend on the selected ChatGPT account and workspace.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Link("Manage ChatGPT usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    Text("ChatGPT credentials stay in this device's Keychain. GSD uses the official OpenAI authorization and Responses API.")
                        .font(.caption).foregroundStyle(.secondary)
                    if account.activeID != nil {
                        Button("Sign out of ChatGPT", role: .destructive) {
                            Task { await cancelInference(); await account.signOut() }
                        }
                        .disabled(account.isBusy)
                    }
                }
            }
            .navigationTitle("ChatGPT account")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { account.cancelSignIn(); dismiss() }
                }
            }
            .task { await account.loadModels() }
            .onDisappear { account.cancelSignIn() }
            .alert("You're using your ChatGPT plan", isPresented: $account.showPlanWelcome) {
                Button("Got it") { account.acknowledgePlanWelcome() }
            } message: {
                Text("Eligible AI requests in GSD use your ChatGPT plan. You can review and manage usage in ChatGPT settings.")
            }
        }
    }
}
