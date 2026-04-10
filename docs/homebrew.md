# Homebrew Distribution

`capcap` is a GUI macOS app, so the right Homebrew packaging is a cask:

```bash
brew install --cask capcap
```

Because this repository is named `capcap` instead of `homebrew-capcap`, Homebrew cannot infer it with the one-argument tap form. Users need the two-argument tap command:

```bash
brew tap realskyrin/capcap https://github.com/realskyrin/capcap
brew install --cask capcap
```

If you want the shorter `brew tap realskyrin/capcap`, create a dedicated tap repository named `realskyrin/homebrew-capcap` and copy the same cask file there.

## Maintainer Flow

1. Build and publish a GitHub Release tag like `release-v1.0.2`.
2. Compute the release archive checksum:

   ```bash
   curl -fsSL -o /tmp/capcap.zip \
     "https://github.com/realskyrin/capcap/releases/download/release-v1.0.2/capcap-1.0.2-macos.zip"
   shasum -a 256 /tmp/capcap.zip
   ```

3. Regenerate the cask file:

   ```bash
   bash scripts/generate-homebrew-cask.sh 1.0.2 <sha256>
   ```

4. Commit the updated `Casks/capcap.rb`.

## Notarization

Homebrew can install an unsigned `.app`, but Gatekeeper may warn or block the first launch. For a smooth install experience, enable Developer ID signing and notarization in the release workflow before distributing broadly.
