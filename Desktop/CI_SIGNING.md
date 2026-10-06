# GitHub Actions Developer ID signing

`.github/workflows/nightly.yml` builds the Apple Silicon Release app using your
**Developer ID Application** certificate. The test workflow remains unsigned.
The signing workflow runs on pushes and manual dispatch, never on pull requests.
Missing or invalid signing secrets fail the build instead of uploading an
unsigned app. The output artifact is `Midoku-macOS.dmg`, uploaded directly with
`actions/upload-artifact@v7` and `archive: false`. No ZIP wrapper or inner ZIP is
created. The compressed, read-only DMG contains `Midoku.app` and an
`Applications` shortcut for drag-and-drop installation. Both the app and DMG
are signed using your certificate; the workflow verifies the app signature,
DMG signature and disk-image checksum before upload.

## Prepare the certificate on your Mac

1. Open **Keychain Access → My Certificates**. Find your **Developer ID
   Application: … (TEAMID)** certificate, expand it, and confirm it has a private
   key. A `.cer` file alone cannot sign the app. Apple Development and Developer
   ID Installer certificates are not suitable for this workflow.
2. Export that certificate and its private key as a password-protected `.p12`
   file. Export only one signing identity. Record its export password.
3. Encode the file and copy the result to the clipboard:

   ```sh
   base64 -i "$HOME/Desktop/Midoku-signing.p12" | tr -d '\n' | pbcopy
   ```

   Adjust the filename to match your export. Do not commit the P12, private key,
   password or Base64 contents, or paste them into chat.

## Configure GitHub

Open your repository's **Settings → Secrets and variables → Actions →
New repository secret**, and add:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_BASE64` | The Base64 P12 copied above |
| `MACOS_CERTIFICATE_PASSWORD` | The nonempty P12 export password |
| `APPLE_TEAM_ID` | Your 10-character Apple developer team ID, as shown in the certificate name |

After the workflow change is pushed, open **Actions → Build native macOS app →
Run workflow**, select the branch containing the change, and run it. Download
`Midoku-macOS.dmg` once the run passes. Open the DMG and drag `Midoku.app` to
`Applications`. Pushes also trigger signed builds;
branches containing this workflow require these secrets.

The workflow imports the identity into a temporary, randomly password-protected
keychain and explicitly selects it for signing. It also adds that keychain to
the user search list so Xcode can discover the identity before invoking
codesign, preserving and restoring the original search list during cleanup.
It uses manual signing with
Hardened Runtime and a secure timestamp, preserving the project's sandbox
entitlements. It verifies the signature and Team ID before packaging, and
deletes the temporary P12 and keychain even when a build fails. No provisioning
profile is needed for the app's current Developer ID entitlements.

This workflow signs the app and DMG but **does not notarize them**. A DMG downloaded from
GitHub can still receive a Gatekeeper warning. Public distribution without that
warning requires a separate Apple notarization step and stapling; Developer ID
signing alone does not establish Gatekeeper acceptance.

## Local verification after download

Open the downloaded DMG, install the app, and run on your Mac:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Midoku.app
codesign --display --verbose=4 /Applications/Midoku.app
```

The display should include `Authority=Developer ID Application: …`, the expected
`TeamIdentifier`, and `Timestamp`. Signature verification alone does not check
notarization status. Renew or replace the repository secrets when the certificate
expires or is revoked.
