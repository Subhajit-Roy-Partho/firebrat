import Foundation
import Security
import Combine
import AuthenticationServices
import CryptoKit
import UIKit

/// Firebase ID tokens and refresh tokens live in Keychain, never preferences.
enum SecureSession {
    static let service = "com.firebrat.native.firebase"
    static var accessToken: String? {
        guard let data = read(), let value = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        return value.idToken
    }
    struct Session: Codable { var idToken: String; var refreshToken: String; var email: String; var expires: Date }
    static func read() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var result: CFTypeRef?; SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }
    static func save(_ value: Session?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var item = query; item[kSecValueData as String] = try JSONEncoder().encode(value)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    }
    static func freshAccessToken() async throws -> String? {
        guard let data = read(), let session = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        if session.expires.timeIntervalSinceNow > 120 { return session.idToken }
        var request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(AuthStore.apiKey)")!)
        request.setValue("com.firebrat.native", forHTTPHeaderField: "X-Ios-Bundle-Identifier"); request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: session.refreshToken)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["id_token"] as? String, let refresh = json["refresh_token"] as? String else { throw APIError.badStatus(401) }
        try save(Session(idToken: token, refreshToken: refresh, email: session.email,
                         expires: Date().addingTimeInterval(Double(json["expires_in"] as? String ?? "3600") ?? 3600)))
        return token
    }
}

@MainActor final class AuthStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    // Public Firebase project configuration, matching the Android client.
    nonisolated static let apiKey = "AIzaSyAfmODlXu1HNUFDkxDMiqraLocieidqBSM"
    @Published var email: String = ""
    @Published var busy = false
    @Published var error: String?
    private var webSession: ASWebAuthenticationSession?
    override init() {
        super.init()
        if let data = SecureSession.read(), let value = try? JSONDecoder().decode(SecureSession.Session.self, from: data) { email = value.email }
    }
    func signOut() { try? SecureSession.save(nil); email = "" }
    private func saveFirebase(_ json: [String: Any]) throws {
        guard let token = json["idToken"] as? String, let refresh = json["refreshToken"] as? String else { throw APIError.decodeFailed("sign-in response") }
        email = json["email"] as? String ?? "Signed in"
        try SecureSession.save(.init(idToken: token, refreshToken: refresh, email: email,
                                    expires: Date().addingTimeInterval(Double(json["expiresIn"] as? String ?? "3600") ?? 3600)))
    }
    private func firebase(_ action: String, body: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:\(action)?key=\(Self.apiKey)")!)
        request.setValue("com.firebrat.native", forHTTPHeaderField: "X-Ios-Bundle-Identifier"); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NSError(domain: "FirebratAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: (json?["error"] as? [String: Any])?["message"] as? String ?? "Sign-in failed"])
        }
        try saveFirebase(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }
    func signIn(email: String, password: String, create: Bool) async {
        busy = true; error = nil; defer { busy = false }
        do { try await firebase(create ? "signUp" : "signInWithPassword", body: ["email": email, "password": password, "returnSecureToken": true]) }
        catch { self.error = error.localizedDescription }
    }
    func signInGoogle() async {
        busy = true; error = nil; defer { busy = false }
        do {
            guard let file = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
                  let config = NSDictionary(contentsOf: file), let client = config["CLIENT_ID"] as? String,
                  let scheme = config["REVERSED_CLIENT_ID"] as? String else {
                throw NSError(domain: "FirebratAuth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Google sign-in configuration is not installed yet."])
            }
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw CocoaError(.coderInvalidValue) }
            let verifier = Data(random).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let state = UUID().uuidString; let redirect = "\(scheme):/oauthredirect"
            var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            parts.queryItems = ["client_id": client, "redirect_uri": redirect, "response_type": "code", "scope": "openid email profile", "state": state, "code_challenge": challenge, "code_challenge_method": "S256"].map { .init(name: $0.key, value: $0.value) }
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                webSession = ASWebAuthenticationSession(url: parts.url!, callbackURLScheme: scheme) { url, error in
                    if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? CocoaError(.userCancelled)) }
                }
                webSession?.presentationContextProvider = self
                if webSession?.start() != true { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
            let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard values.first(where: { $0.name == "state" })?.value == state,
                  let code = values.first(where: { $0.name == "code" })?.value else { throw APIError.decodeFailed("Google authorization") }
            var tokenRequest = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            tokenRequest.httpMethod = "POST"; tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents(); form.queryItems = ["code": code, "client_id": client, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier].map { .init(name: $0.key, value: $0.value) }
            tokenRequest.httpBody = form.percentEncodedQuery?.data(using: .utf8)
            let (tokenData, tokenResponse) = try await URLSession.shared.data(for: tokenRequest)
            guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any], let idToken = json["id_token"] as? String else { throw APIError.decodeFailed("Google token") }
            var assertion = URLComponents(); assertion.queryItems = [.init(name: "id_token", value: idToken), .init(name: "providerId", value: "google.com")]
            try await firebase("signInWithIdp", body: ["postBody": assertion.percentEncodedQuery!, "requestUri": "http://localhost", "returnSecureToken": true, "returnIdpCredential": true])
        } catch { self.error = error.localizedDescription }
        webSession = nil
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? UIWindow()
    }
}
