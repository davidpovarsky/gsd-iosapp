import SwiftUI

struct ThirdPartyNoticesView: View {
    private let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        Group {
            if let notices {
                ScrollView {
                    Text(verbatim: notices)
                        .font(.footnote)
                        .foregroundStyle(Surface.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    String(localized: "Unavailable"),
                    systemImage: "doc.text",
                    description: Text(String(localized: "The license document could not be loaded."))
                )
            }
        }
        .background(Surface.paper)
        .navigationTitle(String(localized: "Open Source Licenses"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("gsd.settings.open-source-licenses.document")
    }
}
