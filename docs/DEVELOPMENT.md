# Development guide

## Local setup

Use Xcode with an iOS 18+ SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Install XcodeGen with `brew install xcodegen`, run `xcodegen generate`, and open `Smail.xcodeproj`. Select the Smail scheme and an iOS simulator. Debug builds include synthetic demo emails; Google credentials are optional for that mode.

Swift Package Manager resolves Google Sign-In and SwiftSoup. Update [`project.yml`](../project.yml) for project or dependency changes, then regenerate the Xcode project.

## Connect Gmail and run on a device

1. Set a bundle identifier you control in `project.yml` under `PRODUCT_BUNDLE_IDENTIFIER`.
2. In [Google Cloud Console](https://console.cloud.google.com/), enable the Gmail API, configure the OAuth consent screen, and add your account as a test user if the project is in Testing mode.
3. Create an **iOS OAuth client** matching that bundle identifier. No Web client secret is needed.
4. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and fill in your Apple development team, Google iOS client ID, and reversed client ID. This local file is ignored by Git.
5. Run `xcodegen generate`, select your device in Xcode, and build the Debug configuration with your signing team. Connect Google in the app.

External/Testing Google grants generally require reauthorization after seven days. Google test-user enrollment is independent of TestFlight enrollment.

## Languages

The default is **System Default**. Settings → Language also offers **简体中文** and **English**. The choice applies immediately and persists across launches without recreating the mailbox state. Unsupported system languages fall back to English when no supported language appears in the preferred language list; Chinese language variants use Simplified Chinese.

Translations live in `Smail/en.lproj/Localizable.strings` and `Smail/zh-Hans.lproj/Localizable.strings`. Keep their keys and format placeholders aligned. Email contents and the fixed Gmail label names are not translated. New synthetic demo batches use the selected language.

## Tests

Choose an installed simulator from `xcrun simctl list devices available`:

```sh
xcodegen generate
xcodebuild test \
  -project Smail.xcodeproj -scheme Smail \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

Replace the simulator name as needed. Tests cover label restrictions, request construction, newest-first selection, persistence/retry/undo, HTML rendering, both language flows, and language selection across launches. They use synthetic mail and mocked responses; real consent and live Gmail synchronization require separate account testing.

## Gmail permissions and local data

Google's `gmail.modify` scope is broader than the app's functionality. Smail enforces its narrower boundary in code: read mail, create `Smail/Useful` and `Smail/NotUseful`, and change membership in those two labels only. It does not delete, trash, archive, send mail, or change read status. The Gmail label catalog is checked before writes.

Pending changes are stored before submission, retried serially, and checked against Google's response. Undo restores only the two Smail label memberships. Credentials are managed by the Google SDK. Local batches are isolated by account, use iOS file protection, and are excluded from backups.

The HTML reader uses SwiftSoup and a non-persistent `WKWebView`. It removes active markup, disables scripts, and restricts network access. Remote images are optional and may tell the sender an email was opened. Supported embedded images come from Gmail; tapped HTTP(S) links open in a Safari view.

### Limits

- Gmail Inbox only, one signed-in account at a time; no background synchronization or push notifications.
- Refresh starts a new batch and undo history. Labels already applied remain in Gmail.
- Renaming or deleting a Smail label can block pending writes until it is restored.
- Concurrent changes to the same labels in other clients cannot be atomically conflict-detected through Gmail's modify API.
- No general attachments or external stylesheets. Embedded images are limited to 12 items and 5 MB decoded total. Some email layouts may render imperfectly.

## Code map

| File in `Smail/` | Role |
| --- | --- |
| `SmailApp.swift` | Screens and card interactions |
| `AppLanguage.swift` | Language preference, resolution, and runtime error presentation |
| `GoogleAuth.swift` | Google sign-in and account lifecycle |
| `GmailClient.swift` | Gmail requests and batch selection |
| `Models.swift` | Models, MIME parsing, and label policy |
| `BatchStore.swift` | Batch state, queued changes, undo, and synthetic demo |
| `Persistence.swift` | Account-isolated storage |
| `MailReader.swift` | HTML sanitization and reader |

## Your own TestFlight build

The optional [`scripts/appstore.mjs`](../scripts/appstore.mjs) helper uses App Store Connect and Node.js 22+. Keep signing keys outside the repository.

1. Create your own App Store Connect app record and signing certificate.
2. Copy `.env.example` to `.env` and fill in the release settings.
3. Copy `Config/ExportOptions.example.plist` to `Config/ExportOptions.plist` and set your team, bundle ID, and profile. Override signing in `Config/Release.local.xcconfig` if needed. These local configuration files are ignored by Git.
4. Update the build number and [`RELEASE_NOTES.md`](../RELEASE_NOTES.md), regenerate the project, and run tests before archiving.

Run commands individually with `node scripts/appstore.mjs COMMAND`:

| Stage | Commands |
| --- | --- |
| Inspect and prepare signing | `status`, `provision` |
| Build and upload | `archive`, `export`, `upload` |
| Check processing and testing group | `testflight`, `prepare-testflight` |
| Publish notes and distribute | `release-notes`, `distribute` |
| Invite an existing internal tester and verify | `invite-owner`, `release-status` |

Wait for Apple to finish processing before distributing. These commands can modify App Store Connect and send invitations. `grant-app-access EMAIL` extends an existing user's role to this app and should only be used with approval.

The helper reads project-local `.env`, or a file selected by `SMAIL_RELEASE_ENV`; environment variables override file values. `APPLE_TEAM_ID` is required for archive, `ASC_DISTRIBUTION_SERIAL` for provisioning, and `SMAIL_TESTER_EMAIL` for invitations. `SMAIL_TESTFLIGHT_GROUP` defaults to `Internal Testing`.

## Contributing

### Demo media

The README demo is an edited recording of the real simulator UI with synthetic messages. `scripts/render_demo.py` adds the branded layout, device frame, chapter captions, and progress indicators; it requires Python with Pillow, ffmpeg, and the macOS supplemental fonts (or matching fonts supplied with `--font-dir`).

Record the English sorting flow and language-selection flow, then choose four source-video ranges: sorting/undo, HTML reading, language selection, and batch completion. For example:

```sh
python3 scripts/render_demo.py recording.mp4 \
  --chapter 13:19.2 --chapter 8.1:12.1 \
  --chapter 44.3:51.1 --chapter 31.8:33.7
```

Adjust the timestamps to your recording. The renderer produces MP4, GIF, and a PNG preview under `docs/assets/`. Keep raw recordings and test outputs in ignored `DerivedData/`.

### Pull requests

Include reproduction steps and your iOS version in bug reports. Use synthetic examples instead of real mail, tokens, or account details. Run relevant tests and preserve the two-label write boundary, including during interrupted requests, retries, undo, and account switches. Third-party dependencies retain their respective licenses.
