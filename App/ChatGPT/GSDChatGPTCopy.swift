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
        guard let planError = error as? HanlinChatGPTPlanError else {
            return error.localizedDescription
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
                          Int64(status), code ?? String(localized: "Unknown"),
                          requestID ?? String(localized: "Unavailable"))
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
}
