import SwiftUI
import GoogleSignIn

@MainActor @Observable final class GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.modify"
    var account: String?
    var email: String?
    var busy = false
    var error: String?
    var configured: Bool { !(Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "unconfigured").contains("unconfigured") }

    func restore() async {
        guard configured else { return }
        busy = true; defer { busy = false }
        do { let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn(); try accept(user) }
        catch { /* A fresh install has no saved grant. Interactive sign-in remains available. */ }
    }
    func signIn() async {
        guard configured else { error = "尚未配置 Smail 的 iOS Google OAuth client。"; return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        busy = true; error = nil; defer { busy = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: email, additionalScopes: [Self.scope])
            try accept(result.user)
        } catch {
            let ns = error as NSError
            if ns.domain != kGIDSignInErrorDomain || ns.code != GIDSignInError.canceled.rawValue { self.error = "Google 授权未完成，请重试并允许 Gmail 标签编辑权限。" }
        }
    }
    private func accept(_ user: GIDGoogleUser) throws {
        guard user.grantedScopes?.contains(Self.scope) == true, let id = user.userID else { throw SmailError.message("需要 Gmail 标签编辑权限。") }
        account = id; email = user.profile?.email
    }
    func token(for expected: String) async throws -> String {
        guard account == expected, let user = GIDSignIn.sharedInstance.currentUser, user.userID == expected else { throw SmailError.message("Google 账号已变化，请重新连接。") }
        let fresh: GIDGoogleUser
        do { fresh = try await user.refreshTokensIfNeeded() }
        catch { throw SmailError.message("Google 授权已失效，请在设置中重新授权；分类进度会保留。") }
        guard account == expected, fresh.userID == expected, fresh.grantedScopes?.contains(Self.scope) == true else { throw SmailError.message("请重新授权 Gmail 标签权限。") }
        return fresh.accessToken.tokenString
    }
    func signOut() { GIDSignIn.sharedInstance.signOut(); account = nil; email = nil }
    func disconnect() async {
        busy = true; error = nil; defer { busy = false }
        do { try await GIDSignIn.sharedInstance.disconnect(); account = nil; email = nil }
        catch { self.error = "Google 未确认撤销授权，请稍后重试。" }
    }
}
