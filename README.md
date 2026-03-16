# quigsphoto-uploader

A macOS CLI tool that processes Lightroom-exported photos, uploads them to Ghost CMS with scheduling, and emails 365 Project photos. Designed to be invoked by Hazel.

## Installation

```bash
brew tap quigs/tools /Users/wash/Developer/tools/quigsphoto-uploader
brew install --HEAD quigs/tools/quigsphoto-uploader
```

## Usage

### Initial setup

```bash
quigsphoto-uploader setup
```

Walks you through configuring Ghost CMS, SMTP, processing settings, and stores secrets in the macOS Keychain.

### Process a folder

```bash
quigsphoto-uploader process /path/to/exported/photos
```

Options:

- `--dry-run` — Preview actions without uploading or emailing
- `--verbose-results` — Include successful images in result output
- `--json-results` — Write a single JSON results file instead of individual text files
- `--results-dir <path>` — Directory to write result files to (default: input folder)

## Development

### Prerequisites

- macOS 13+
- Xcode 26+ or Swift 6.2+ toolchain

### Build and test

```bash
swift build
swift test
```

### Install locally via Homebrew

```bash
brew tap quigs/tools /Users/wash/Developer/tools/quigsphoto-uploader
brew install --HEAD quigs/tools/quigsphoto-uploader
```

After making changes, rebuild and reinstall:

```bash
# Sync the tap with your local repo
cd /opt/homebrew/Library/Taps/quigs/homebrew-tools && git pull origin main

# Reinstall from HEAD
brew reinstall --HEAD quigs/tools/quigsphoto-uploader
```

### Creating a release with bottles

Bottles are prebuilt binaries so users don't need Xcode to install.

**Automated (GitHub Actions):** Push a tag and create a GitHub release — the `bottle.yml` workflow builds and uploads a bottle automatically.

```bash
git tag v1.0.0
git push origin v1.0.0
gh release create v1.0.0 --generate-notes
# Workflow uploads bottle, then update formula with the bottle block from the workflow output
```

**Manual (local):**

```bash
./scripts/create-bottle.sh 1.0.0
# Upload the .tar.gz to the GitHub release
# Paste the bottle block into Formula/quigsphoto-uploader.rb
```

### Switching to GitHub

When publishing to GitHub, update `Formula/quigsphoto-uploader.rb`:

1. Replace the local `head` URL with the GitHub URL:
   ```ruby
   head "https://github.com/josephquigley/quigsphoto-uploader.git", branch: "main"
   ```
2. Add `url`, `sha256`, and `bottle` block for the tagged release.
3. Update the tap to point at the GitHub repo:
   ```bash
   brew untap quigs/tools
   brew tap quigs/tools https://github.com/josephquigley/quigsphoto-uploader.git
   ```
