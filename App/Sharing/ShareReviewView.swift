import SwiftUI
import GSDSnapshot

/// Preserved captures are reviewed explicitly; another account's content is never listed.
struct ShareReviewView: View {
    @Environment(ShareInboxDrainer.self) private var drainer

    var body: some View {
        List {
            Section {
                Text(String(localized: "Saved shares stay on this device until their original account and task collection can be verified."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Try adding saved shares again")) {
                    _Concurrency.Task { await drainer.drain() }
                }
            }
            let items = drainer.reviewItems()
            if items.isEmpty {
                Text(String(localized: "No saved shares are ready to review."))
            }
            ForEach(items) { item in
                if let lease = item.reviewLease {
                    NavigationLink {
                        ShareCaptureReviewDetail(capture: item.capture, lease: lease)
                    } label: {
                        Text(item.capture.origin == nil
                             ? String(localized: "Review a saved share")
                             : item.capture.title)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Saved share"))
                        Text(item.needsOriginalAccount
                             ? String(localized: "Sign in to the original account to review this share. Its content has been preserved.")
                             : String(localized: "Wait for GSD to verify the current account, then try again."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Saved Shares"))
        .task { drainer.refreshPending() }
    }
}

private struct ShareCaptureReviewDetail: View {
    @Environment(ShareInboxDrainer.self) private var drainer
    let capture: SharedCapture
    @State private var lease: ShareInboxDrainer.ReviewLease

    init(capture: SharedCapture, lease: ShareInboxDrainer.ReviewLease) {
        self.capture = capture
        // Destination value updates must never replace the authority selected on first open.
        _lease = State(initialValue: lease)
    }

    private var text: String {
        ([capture.title] + capture.urls + [capture.tags.map { "#" + $0 }.joined(separator: " ")])
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        Form {
            if drainer.isReviewCurrent(lease) {
                Section { Text(text).textSelection(.enabled) }
                Section {
                    ShareLink(item: text) {
                        Label(String(localized: "Share as a new task"), systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(capture.isEditedRetry == true
                         ? String(localized: "These retry edits were not applied to the existing task. Choose GSD when sharing to create a new task. The existing task and saved copy stay unchanged.")
                         : String(localized: "Choose GSD when sharing to create a new task in the selected account. The original saved copy stays unchanged."))
                }
            } else {
                Text(String(localized: "The account or task collection changed. Return to Saved Shares and select this item again."))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Review Saved Share"))
    }
}
