import Foundation
import HanlinChatCore

enum GSDChatGPTSessionError: LocalizedError {
    case refreshNotYetPermitted

    var errorDescription: String? {
        String(localized: "ChatGPT session refresh is not yet permitted. Try again shortly.")
    }
}

/// Localize framework errors at the host boundary while preserving diagnostic codes.
enum GSDChatGPTCopy {
    static func error(_ error: any Error) -> String {
        if let transport = error as? HanlinChatGPTPlanTransportError {
            switch transport {
            case .invalidRoute:
                return String(localized: "ChatGPT plan requests require the official OpenAI Responses endpoint.")
            case .invalidBody:
                return String(localized: "The ChatGPT request or response format was invalid. Try again.")
            case .unsupportedTool:
                return String(localized: "This tool is unavailable through ChatGPT plan usage.")
            case .incompleteStream:
                return String(localized: "The ChatGPT response was interrupted before completion. Try again.")
            case .response(let detail):
                let diagnostic = String(format: String(localized:
                    "OpenAI request failed (HTTP %lld, code: %@, parameter: %@, request: %@)."),
                    Int64(detail.status), safeCode(detail.code), safeCode(detail.parameter),
                    safeCode(detail.requestID, fallback: String(localized: "Unavailable")))
                switch detail.code {
                case "subscription_sharing_usage_limit_exceeded":
                    return String(localized: "The ChatGPT usage limit for this app has been reached. Review ChatGPT Settings → Usage.")
                        + "\n" + diagnostic
                case "subscription_sharing_usage_unavailable":
                    return String(localized: "ChatGPT plan usage is unavailable for this account or workspace.")
                        + "\n" + diagnostic
                default: return diagnostic
                }
            }
        }
        guard let planError = error as? HanlinChatGPTPlanError else {
            return Bundle.main.localizedString(
                forKey: error.localizedDescription, value: error.localizedDescription, table: nil)
        }
        switch planError {
        case .invalidRedirect:
            return String(localized: "The OpenAI sign-in callback is invalid.")
        case .denied:
            return String(localized: "ChatGPT sign-in was declined.")
        case .server(let status):
            return String(format: String(localized: "OpenAI authentication returned HTTP %lld."), Int64(status))
        case .oauth(let status, let code, let requestID):
            return String(format: String(localized: "OpenAI request failed (HTTP %lld, code: %@, request: %@)."),
                          Int64(status), safeCode(code),
                          safeCode(requestID, fallback: String(localized: "Unavailable")))
        case .invalidToken:
            return String(localized: "OpenAI returned a token that could not be verified.")
        case .invalidIdentity:
            return String(localized: "OpenAI identity could not be verified.")
        case .invalidAuthorization:
            return String(localized: "OpenAI authorization is incomplete or expired.")
        case .unavailable:
            return String(localized: "ChatGPT account access is unavailable. Check your sign-in and plan permissions.")
        }
    }

    private static func safeCode(_ value: String?, fallback: String = String(localized: "Unknown")) -> String {
        guard let value, !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "._-[]".unicodeScalars.contains($0)
              }) else { return fallback }
        return value
    }

}
