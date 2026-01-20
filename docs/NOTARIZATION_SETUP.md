# macOS Notarization Setup Guide

This guide walks you through setting up code signing and notarization for Claude HUD distribution.

## Prerequisites

- **Apple Developer Program membership** ($99/year) — Required for Developer ID certificates
- **macOS with Xcode Command Line Tools** — `xcode-select --install`

## Step 1: Create Developer ID Certificate

1. Go to [Apple Developer Certificates](https://developer.apple.com/account/resources/certificates/list)
2. Click the **+** button to create a new certificate
3. Select **Developer ID Application** (for distributing outside the App Store)
4. Follow the prompts to create a Certificate Signing Request (CSR) using Keychain Access
5. Download and double-click the certificate to install it in your Keychain

### Verify Installation

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see output like:
```
1) ABC123... "Developer ID Application: Your Name (TEAM_ID)"
```

## Step 2: Generate App-Specific Password

Apple requires an app-specific password for notarization (not your Apple ID password).

1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign in and go to **Security** → **App-Specific Passwords**
3. Click **Generate an app-specific password**
4. Name it something like "ClaudeHUD Notarization"
5. **Copy the password** — you'll only see it once!

## Step 3: Find Your Team ID

Your Team ID is shown in the certificate name (the 10-character code in parentheses).

Alternatively, find it at:
1. [Apple Developer Membership](https://developer.apple.com/account#MembershipDetailsCard)
2. Look for "Team ID" in your membership details

## Step 4: Store Credentials in Keychain

Run this command, replacing the placeholders:

```bash
xcrun notarytool store-credentials "ClaudeHUD" \
  --apple-id "your-apple-id@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

This stores the credentials securely in your macOS Keychain under the profile name "ClaudeHUD".

### Verify Credentials

```bash
xcrun notarytool history --keychain-profile "ClaudeHUD"
```

If credentials are valid, you'll see your notarization history (or an empty list if this is your first time).

## Step 5: Test the Full Build

```bash
# Build with notarization (full release process)
./scripts/build-distribution.sh

# Or skip notarization for faster local testing
./scripts/build-distribution.sh --skip-notarization
```

## Troubleshooting

### "No Developer ID Application certificate found"

- Ensure you created a **Developer ID Application** certificate (not a development or distribution cert)
- Check that the certificate is in your **login** keychain, not System
- Try: `security find-identity -v -p codesigning` to list all signing identities

### "Unable to authenticate" during notarization

- Verify your app-specific password is correct
- Ensure you're using your Apple ID email, not an alias
- Re-run the `store-credentials` command with correct values

### "The signature is invalid" or Gatekeeper blocks the app

- Ensure hardened runtime is enabled (the scripts do this automatically)
- Check that all binaries are signed, including dylibs in Frameworks/
- Run: `codesign -dvvv ClaudeHUD.app` to inspect the signature

### Notarization takes too long

- Typical time: 5-15 minutes
- Check status: `xcrun notarytool history --keychain-profile "ClaudeHUD"`
- Apple's servers occasionally have delays

## Security Notes

- **Never commit** your app-specific password to version control
- The Keychain profile is stored locally and securely encrypted
- Developer ID certificates are tied to your Apple Developer account

## References

- [Apple: Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Apple: Create Developer ID Certificate](https://developer.apple.com/help/account/create-certificates/create-developer-id-certificates)
- [notarytool Documentation](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow)
