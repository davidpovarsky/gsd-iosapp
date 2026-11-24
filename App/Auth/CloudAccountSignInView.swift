import SwiftUI

/// A single cloud account is used by native GSD and by the ChatGPT MCP plugin.
/// Both clients authenticate to the same server — no device pairing required.
struct CloudAccountSignInView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var createAccount = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Account mode"), selection: $createAccount) {
                        Text(String(localized: "Sign in")).tag(false)
                        Text(String(localized: "Create account")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("gsd.cloud.mode")
                    TextField(String(localized: "Email address"), text: $email)
                        .accessibilityIdentifier("gsd.cloud.email")
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField(String(localized: "Password"), text: $password)
                        .accessibilityIdentifier("gsd.cloud.password")
                        .textContentType(createAccount ? .newPassword : .password)
                    if createAccount {
                        SecureField(String(localized: "Confirm password"), text: $confirmation)
                            .accessibilityIdentifier("gsd.cloud.confirmation")
                            .textContentType(.newPassword)
                    }
                } header: {
                    Text(String(localized: "GSD Cloud account"))
                } footer: {
                    Text(String(localized:
                        "Use the same account in ChatGPT and on every device. ChatGPT can manage your cloud tasks while this app is closed."))
                }
                Section {
                    if let message = localError ?? session.lastError {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel(message)
                    }
                    Button {
                        submit()
                    } label: {
                        if session.inProgress {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Text(createAccount ?
                                String(localized: "Create GSD account") :
                                String(localized: "Sign in to GSD Cloud"))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .accessibilityIdentifier("gsd.cloud.submit")
                    .buttonStyle(.borderedProminent)
                    .disabled(session.inProgress || email.trimmingCharacters(in: .whitespaces).isEmpty
                              || (createAccount ? password.count < 10 : password.isEmpty))
                }
            }
            .navigationTitle(String(localized: "Cloud account"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .onChange(of: session.isSignedIn) { _, signedIn in
                if signedIn {
                    password = ""
                    confirmation = ""
                    dismiss()
                }
            }
        }
    }

    private func submit() {
        localError = nil
        if createAccount && password != confirmation {
            localError = String(localized: "Passwords do not match.")
            return
        }
        _Concurrency.Task {
            await session.signInWithEmail(email, password: password,
                                          createAccount: createAccount)
        }
    }
}
