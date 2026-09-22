# Releasing Kit

Kit uses Sparkle without Developer ID signing or Apple notarization. GitHub Releases hosts update ZIPs and GitHub Pages serves the signed appcast.

## One-time setup

- Keep an `Apple Development` certificate in the login Keychain
- Keep the Sparkle private key only in the Keychain and the repository's `SPARKLE_PRIVATE_KEY` Actions secret
- Serve GitHub Pages from `main` and `/docs`

This free distribution path is rejected by Gatekeeper on first download. Users may need to right-click Open or allow the app in System Settings. Sparkle's EdDSA signature protects subsequent updates but does not replace Apple notarization.

## Publish

From a clean `main` branch, run:

```bash
./scripts/release.sh 0.1.3 2
```

The script updates both version fields, creates a version commit, archives with the free Apple Development certificate, pushes `main`, and creates a GitHub Release containing the ZIP. The Release description is always empty.

The `Publish Sparkle Appcast` workflow then signs the ZIP with the repository secret and commits the updated `docs/appcast.xml` to `main`.
