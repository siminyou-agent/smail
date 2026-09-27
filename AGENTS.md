# Smail

Independent native SwiftUI Gmail triage app. No Family identity or server dependency.

- Write operations are limited to creating `Smail/Useful`, `Smail/NotUseful` and changing message membership in those two custom labels. Never change system labels, delete/trash/archive/send mail or expose arbitrary Gmail write requests.
- OAuth uses Google's iOS SDK; no client secret or tokens in source, logs, defaults or fixtures.
- Persist mutation intent before sending; retries and undo must preserve unrelated labels. Account changes cannot reuse another account's state.
- Generate Xcode project with `xcodegen generate`. Local signing/client ID settings belong in ignored `Config/Local.xcconfig`.
- Run core policy/persistence tests and simulator UI acceptance before device installation. Build and tests sequentially.
- Do not publish, push or upload to TestFlight without request.
