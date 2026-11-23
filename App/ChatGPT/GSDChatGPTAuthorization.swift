import AuthenticationServices
import Foundation
import HanlinChatCore
import Network
import UIKit

enum GSDChatGPTAuthorizationError: LocalizedError {
    case cancelled, unavailable, timedOut

    var errorDescription: String? {
        switch self {
        case .cancelled: String(localized: "ChatGPT sign-in was cancelled.")
        case .unavailable: String(localized: "The secure ChatGPT sign-in window could not open.")
        case .timedOut: String(localized: "ChatGPT sign-in timed out. Please try again.")
        }
    }
}

/// The official public-client flow requires a loopback callback. The listener
/// binds only 127.0.0.1 and closes the system authentication session after a
/// state-validated callback, without passing tokens through a custom URL scheme.
@MainActor
final class GSDChatGPTAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var listener: NWListener?
    private var browser: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var pending: HanlinChatGPTAuthorizationAttempt?
    private var completion: CheckedContinuation<(URL, HanlinChatGPTAuthorizationAttempt), Error>?
    private var timeout: _Concurrency.Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]

    func authenticate(
        attempt: @escaping @MainActor (UInt16) throws -> HanlinChatGPTAuthorizationAttempt
    ) async throws -> (URL, HanlinChatGPTAuthorizationAttempt) {
        guard completion == nil else { throw GSDChatGPTAuthorizationError.unavailable }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                do { try start(attempt: attempt) }
                catch { finish(.failure(error)) }
            }
        } onCancel: {
            _Concurrency.Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(GSDChatGPTAuthorizationError.cancelled)) }

    private func start(
        attempt: @escaping @MainActor (UInt16) throws -> HanlinChatGPTAuthorizationAttempt
    ) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.keyWindow else { throw GSDChatGPTAuthorizationError.unavailable }
        anchor = window
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.stateUpdateHandler = { @Sendable [weak self, weak server] state in
            _Concurrency.Task { @MainActor [weak self, weak server] in
                guard let self, let server, self.listener === server else { return }
                switch state {
                case .ready:
                    guard let port = server.port else {
                        self.finish(.failure(GSDChatGPTAuthorizationError.unavailable))
                        return
                    }
                    do { try self.openBrowser(attempt(port.rawValue)) }
                    catch { self.finish(.failure(error)) }
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
        }
        server.newConnectionHandler = { @Sendable [weak self] connection in
            _Concurrency.Task { @MainActor [weak self] in self?.accept(connection) }
        }
        server.start(queue: .main)
        timeout = _Concurrency.Task { @MainActor [weak self] in
            do { try await _Concurrency.Task.sleep(for: .seconds(300)) }
            catch { return }
            self?.finish(.failure(GSDChatGPTAuthorizationError.timedOut))
        }
    }

    private func openBrowser(_ attempt: HanlinChatGPTAuthorizationAttempt) throws {
        guard browser == nil else { return }
        pending = attempt
        let session = ASWebAuthenticationSession(url: attempt.url, callbackURLScheme: nil) {
            @Sendable [weak self] _, error in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.completion != nil else { return }
                if let error, case ASWebAuthenticationSessionError.canceledLogin = error {
                    self.cancel()
                } else {
                    self.finish(.failure(error ?? GSDChatGPTAuthorizationError.unavailable))
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        browser = session
        guard session.start() else { throw GSDChatGPTAuthorizationError.unavailable }
    }

    private func accept(_ connection: NWConnection) {
        guard pending != nil, connections.count < 8,
              case .hostPort(let host, _) = connection.endpoint,
              host == NWEndpoint.Host("127.0.0.1") else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - buffer.count) {
            @Sendable [weak self] bytes, _, complete, error in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self, self.connections[id] != nil else { connection.cancel(); return }
                let accumulated = buffer + (bytes ?? Data())
                guard error == nil, !accumulated.isEmpty, accumulated.count <= 16_384 else {
                    self.close(connection, id: id)
                    return
                }
                if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(accumulated, connection: connection, id: id)
                } else if complete || accumulated.count == 16_384 {
                    self.close(connection, id: id)
                } else {
                    self.receive(connection, id: id, buffer: accumulated)
                }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard let attempt = pending,
              let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first else {
            close(connection, id: id)
            return
        }
        let fields = line.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET",
              fields[1].hasPrefix("/auth/callback?"),
              let callback = URL(string: "http://127.0.0.1:\(attempt.redirectURI.port ?? 0)\(fields[1])"),
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.path == "/auth/callback", components.fragment == nil,
              components.queryItems?.filter({ $0.name == "state" }).count == 1,
              components.queryItems?.first(where: { $0.name == "state" })?.value == attempt.state else {
            close(connection, id: id)
            return
        }
        let body = "<!doctype html><html><meta charset=utf-8><title>GSD Tasks</title><body>Sign-in response received. Return to GSD Tasks.</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed {
            @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.close(connection, id: id)
                self?.finish(.success((callback, attempt)))
            }
        })
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connections.removeValue(forKey: id)
        connection.cancel()
    }

    private func finish(_ result: Result<(URL, HanlinChatGPTAuthorizationAttempt), Error>) {
        guard let continuation = completion else { return }
        completion = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        pending = nil
        browser?.cancel(); browser = nil
        anchor = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let anchor else { preconditionFailure("Missing authentication presentation anchor") }
        return anchor
    }
}
