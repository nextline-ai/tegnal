# Google Drive sync setup

The Flutter app supports Google Drive on Android, Windows, and Linux. A Google Cloud project and OAuth clients must be created before connecting an account. A build with empty configuration displays a setup message and does not open a sign-in window. OAuth has been tested with local fixtures; live Google authorization still requires the project, clients, and platform checks below.

## Google Cloud project

1. Create or select one project in [Google Cloud Console](https://console.cloud.google.com/). Enable **Google Drive API** in its API Library.
2. Configure the Google Auth Platform branding, support email, audience, and developer contact information. For an External audience in Testing, add the Google accounts that will test TEGNAL. Complete the publication requirements applicable to your intended audience before wider distribution.
3. Configure the Drive permission `https://www.googleapis.com/auth/drive.file`. Desktop sign-in also requests `openid` and `email` to identify the account. Keep all of the following OAuth clients in this same project.

TEGNAL uses the non-sensitive `drive.file` scope to manage its own JSON snapshots in an app-created, visible `TEGNAL` folder. It does not request permission to scan the user's entire Drive. An existing unrelated folder with that name does not grant access to its other contents. Google documents this per-file access model in [Drive authorization scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

## Android clients and signing

Create an **Android** OAuth client with package name `work.nextline.tegnal` and the SHA-1 fingerprint of the certificate that actually signs the installed app. Register each signing certificate used for development and release. From `flutter/android`, inspect Gradle's signing report:

```sh
./gradlew signingReport
```

On Windows use `gradlew.bat signingReport`. For Play-distributed builds, register the **Play app signing** certificate from Play Console's App integrity page; the upload certificate can differ. For directly installed release APKs, use their release keystore certificate. Do not commit a signing keystore or its passwords.

Also create a **Web application** OAuth client. Copy its **client ID** into `GOOGLE_WEB_CLIENT_ID`. The Android implementation passes this Web ID to `GoogleSignIn.initialize(serverClientId: ...)`; the Android client identifies the package/signing certificate. No Web client secret, backend, service account, or Firebase project is needed for this setup. TEGNAL supplies the ID directly and does not depend on `google-services.json`. See the official plugin's [Android configuration instructions](https://pub.dev/packages/google_sign_in_android).

Android uses the official Google Sign-In SDK for account selection and authorization. The requested Drive scope is checked separately after authentication. Silent restoration never initiates an interactive permission request.

## Windows and Linux desktop client

Create an OAuth client with application type **Desktop app**. Copy the downloaded installed-client configuration's `client_id` and `client_secret` fields into `GOOGLE_DESKTOP_CLIENT_ID` and `GOOGLE_DESKTOP_CLIENT_SECRET` respectively. This is Google's installed/public-client secret, distributed with the desktop application. Do not substitute a Web application's confidential client secret.

Desktop authentication opens the system browser, uses PKCE with S256, verifies a random state, and receives the authorization code at `http://127.0.0.1:<ephemeral-port>/oauth2callback`. The loopback server listens only on the IPv4 loopback interface and closes on success, cancellation, failure, or a three-minute authorization timeout. The Desktop app client type supports this installed-app redirect flow; do not create a Web redirect URL with a guessed fixed port. See Google's [desktop OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app).

## Local build configuration

Create `flutter/.env.drive.json`. The Flutter ignore file explicitly excludes `.env.drive.json` (the root also ignores `.env.*`); verify it stays ignored with `git check-ignore flutter/.env.drive.json` from the repository root. Populate only the fields used by the build target. Empty values below deliberately keep the feature unconfigured; replace them with the real values from your project.

```json
{
  "GOOGLE_WEB_CLIENT_ID": "",
  "GOOGLE_DESKTOP_CLIENT_ID": "",
  "GOOGLE_DESKTOP_CLIENT_SECRET": ""
}
```

From `flutter/`, pass that file when running or building:

```sh
flutter run -d windows --dart-define-from-file=.env.drive.json
flutter run -d linux --dart-define-from-file=.env.drive.json
flutter build apk --dart-define-from-file=.env.drive.json
```

Build desktop binaries on their supported host operating system. Release builds need the same defines; the settings are compiled into the application. Do not put access tokens, refresh tokens, service account keys, or server credentials in this file.

## Desktop packaging and credentials

Linux builds require `libsecret-1-dev`; packaged applications require `libsecret-1-0` and an available, unlocked desktop Secret Service/keyring. On Debian/Ubuntu, install both with `sudo apt install libsecret-1-dev libsecret-1-0`. GNOME Keyring and compatible desktop keyring services provide the Secret Service. Modern `flutter_secure_storage` no longer needs `libjsoncpp-dev`. Include the runtime dependency in Linux packages and allow the system browser and loopback callback in any sandbox packaging. See [flutter_secure_storage platform setup](https://pub.dev/packages/flutter_secure_storage).

Desktop refresh credentials and the associated account ID/email are stored only through OS secure storage, under a namespace derived from the OAuth client ID. Access tokens are held in memory and refreshed before expiry. They are never written to SQLite, exported backups, or application logs. Android's Google SDK manages its account credentials. Disconnect clears the local account and credentials and attempts Google revocation; an offline device may require removing TEGNAL later from the account's connected-app permissions as well.

## Synchronization behavior

Drive snapshots are immutable native JSON revision files in the app-created `TEGNAL` folder. Synchronization appends revisions instead of overwriting an existing file. A clean device can pull a newer snapshot with exact deletion semantics. If both copies changed, or concurrent uploads created sibling revisions, synchronization pauses for a whole-library choice: use this device, use a Drive copy, or combine. Combining retains unique entries and uses Drive metadata for duplicates.

Android OS backup and device-transfer rules exclude the local Drive comparison/recovery directory, so a restored device establishes a fresh baseline instead of inheriting another device’s sync authority.

Automatic sync is optional and off by default. When enabled, it operates while the app is open and foregrounded. Before applying an incoming library, TEGNAL keeps a local recovery snapshot and retains the latest ten copies. Restoring a recovery copy first saves the current library and switches automatic sync off, so recovery does not immediately publish over Drive.

## Verify after configuring OAuth

- Android: connect using both debug and release signing configurations, grant Drive file access, and confirm that cancelling leaves local data intact.
- Windows/Linux: connect through the system browser, restart and restore an opted-in account, and confirm a locked/missing keyring produces a recoverable error.
- Confirm the visible `TEGNAL` folder contains the app's snapshots, automatic sync runs only when enabled, disconnect prevents later synchronization, and reconnecting a different Google account uses that account's own snapshots.
- Import a native TEGNAL JSON backup locally before syncing it. Download an exported JSON snapshot directly and import it on iPhone when transferring back; native iOS Google sign-in is outside this Flutter implementation.

No Google project, test account, OAuth IDs, signing fingerprints, or live Drive verification are included in the repository. The focused offline check is `flutter test test/core/drive_auth_test.dart`; it exercises PKCE/state verification, refresh/expiry, error sanitization, and cancellation races without contacting Google.
