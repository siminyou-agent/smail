# OAuth review: Smail

This document describes the app's implementation and intended permission use. It is not a statement that Google has verified the app.

- Product: **Smail: Swipe mail**
- Homepage: https://smail.simin.you/
- Privacy policy: https://smail.simin.you/privacy.html
- Platform: native iOS application, with the Google Sign-In iOS SDK.

## User-facing purpose

Smail is an email productivity client that helps users read and classify their own Gmail Inbox in small batches. Users read a message and choose Useful or Not Useful. The choice is stored as one of two Gmail labels, and can be undone. This is a user-facing email management feature, not advertising, data resale, or generalized AI training.

## Requested scopes

| Scope | Purpose |
| --- | --- |
| `openid` | Authenticate the Google account and keep account-specific application state isolated. |
| `userinfo.email` | Identify and display the signed-in account's email address. |
| `userinfo.profile` | Basic identity scope used by Google Sign-In; the app uses the returned account identity for its signed-in session. |
| `gmail.modify` | Read Inbox messages and modify message membership in the two Smail classification labels. |

### Why `gmail.modify` is needed

The app reads message metadata and bodies so the user can make an informed classification decision. It also calls `users.messages.modify` to add/remove `Smail/Useful` and `Smail/NotUseful` on a message. `gmail.readonly` cannot perform this write. `gmail.labels` manages label definitions but does not authorize the message-membership modification endpoint. Smail does not request the broader full-mailbox `https://mail.google.com/` scope.

Although `gmail.modify` grants broader capabilities, the app exposes only read operations, creation of the two custom labels, and their message-membership changes. It does not send, delete, trash, archive, or mark messages as read. The write policy validates label names/types and restricts each mutation to the two permitted custom label IDs.

References: [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [messages.modify authorization scopes](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/modify).

## Data flow and storage

1. Google Sign-In runs on the user's iOS device and obtains authorization from Google.
2. The Google SDK manages credentials on the device.
3. The device sends authenticated HTTPS requests directly to Google's Gmail API.
4. Message data is shown on-device. Current batches and pending changes are persisted under iOS file protection, separated by account, and excluded from backups.
5. The maintainer operates no application backend receiving Gmail data or OAuth tokens. GitHub Pages serves the public website only; it is not an OAuth callback or mail-processing service.
6. Remote message images are blocked until enabled by the user. If enabled, their URLs are fetched by the device; tapped links open in a Safari view. These external contacts are disclosed in the privacy policy.

The app does not transmit mail to analytics or AI services. Google determines whether the submitted implementation qualifies for any exception from an external security assessment; this document does not claim that approval.

## Source references

- [`GoogleAuth.swift`](../Smail/GoogleAuth.swift): sign-in, granted-scope checks, account-bound token access, sign-out and revocation.
- [`GmailClient.swift`](../Smail/GmailClient.swift): private transport, permitted endpoints, newest-first Inbox selection, and label changes.
- [`Models.swift`](../Smail/Models.swift): label policy and mail models.
- [`BatchStore.swift`](../Smail/BatchStore.swift) and [`Persistence.swift`](../Smail/Persistence.swift): retry/undo queue and account-isolated local storage.
- [`MailReader.swift`](../Smail/MailReader.swift): HTML sanitization, script restrictions, and remote-image controls.

## Verification demonstration

The marketing video uses synthetic demo mail and does **not** demonstrate Google authorization. A separate verification recording must show:

1. The actual app in English, beginning Google sign-in.
2. The OAuth consent flow, its displayed app name, and the OAuth client identification requested by Google's review guidance.
3. The requested permissions and completion of authorization with a designated test account.
4. Loading controlled test emails, opening a message, and choosing Useful or Not Useful.
5. The resulting Gmail labels and undo restoring the prior label membership, without changing read status or removing Inbox membership.
6. The account controls for sign-out and revocation, and where to find the privacy policy.

Use purpose-made test messages and avoid showing unrelated personal mail, credentials, or recovery information. Google currently requests an unlisted YouTube link for the review video. Each production OAuth client included in the submission must be covered as required by the review team.
