<p align="center">
  <img src="logo.svg" alt="piqley" width="460"/>
</p>

<h1 align="center">piqley</h1>

<p align="center">
  A plugin-driven photographer workflow engine for macOS.
</p>

---

Piqley processes exported photos and publishes them to any service with an API or CLI: Ghost, WordPress, Squarespace, email, social media, or your own custom workflow.

Want to export full-resolution photos with all metadata but strip GPS and private tags before publishing? Piqley can do that. Want to use keyword metadata and IPTC tags to draft a social media post without typing anything, #AnalogFilmIsNotDead? Piqley can do that. Want to use different hashtags for different services? Piqley can do that. Under the hood, everything is a [plugin](#plugin-system). Mix and match first-party and custom plugins into a pipeline that fits your workflow.

It works with any photo editor that exports to a folder (Lightroom, Capture One, Apple Photos, darktable, RawTherapee, etc.) and pairs well with [Hazel](https://www.noodlesoft.com) on macOS or any folder-watching automation for a fully hands-off workflow.

## Installation

```bash
brew tap quigs/tools https://github.com/josephquigley/piqley.git
brew install quigs/tools/piqley
```

## Quick Start

```bash
# Interactive setup - installs bundled plugins and configures secrets
piqley setup

# Process a folder of exported photos
piqley process /path/to/exported/photos
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `piqley setup` | Interactive configuration and bundled plugin installation |
| `piqley process <path>` | Process and publish photos from a folder |
| `piqley plugin setup [name]` | Configure a specific plugin (use `--force` to re-run setup) |
| `piqley secret set <key>` | Store a secret in the macOS Keychain |
| `piqley secret delete <key>` | Remove a secret from the Keychain |
| `piqley clear-cache` | Clear plugin execution logs (`--plugin <name>` for a specific plugin) |
| `piqley verify <image>` | Verify a GPG signature on an image |

### Process Options

- `--dry-run` - Preview actions without uploading or emailing
- `--verbose-results` - Include successful images in result output
- `--json-results` - Write a single JSON results file instead of individual text files
- `--results-dir <path>` - Directory to write result files to (default: input folder)

## Plugin System

Piqley's core is a lightweight orchestrator. All real work (image processing, uploading, scheduling) is handled by plugins running as isolated subprocesses.

### How Plugins Work

A plugin is a directory inside `~/.config/piqley/plugins/<plugin-name>/` containing a `manifest.json` and an executable. Write plugins in any language: Swift, Python, Go, Bash, or anything else that can read JSON from stdin and write JSON lines to stdout.

```
~/.config/piqley/plugins/my-plugin/
├── manifest.json    # Declarative: config schema, hooks, setup command
├── config.json      # Mutable: resolved values (managed by piqley)
├── data/            # Plugin working directory
└── bin/             # Plugin executables
```

### Pipeline

Plugins register for hooks in a five-stage pipeline:

| Hook | Purpose |
|------|---------|
| `pre-process` | Modify images before processing (e.g. watermarking) |
| `post-process` | Modify images after processing (e.g. resize, metadata) |
| `publish` | Upload or distribute processed images |
| `schedule` | Schedule or queue posts |
| `post-publish` | Clean up, notify, or log after publishing |

The pipeline order is configured in `~/.config/piqley/config.json`:

```json
{
  "autoDiscoverPlugins": true,
  "pipeline": {
    "post-process": ["piqley-metadata", "piqley-resize"],
    "publish": ["piqley-ghost"]
  }
}
```

### Communication Protocol

Plugins communicate over stdin/stdout using one of two protocols:

**JSON protocol** (default). Piqley sends a JSON object on stdin and the plugin streams JSON lines back:

```json
{"type": "progress", "message": "Uploading photo.jpg..."}
{"type": "imageResult", "filename": "photo.jpg", "success": true}
{"type": "result", "success": true, "error": null}
```

**Pipe protocol.** Context is passed via environment variables and stdout/stderr are forwarded directly. Exit code determines success.

### Building Plugins

The [piqley plugin SDK](https://github.com/josephquigley/piqley-plugin-sdk) provides libraries for Swift, Python, Node.js, and Go. You can also skip the SDK entirely and write a plain executable. See the SDK README for the full manifest schema and protocol details.

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
brew tap quigs/tools /path/to/quigsphoto-uploader
brew install --HEAD quigs/tools/piqley
```

After making changes, rebuild and reinstall:

```bash
cd /opt/homebrew/Library/Taps/quigs/homebrew-tools && git pull origin main
brew reinstall --HEAD quigs/tools/piqley
```

### Creating a release with bottles

Bottles are prebuilt binaries so users don't need Xcode to install.

**Automated (GitHub Actions):** Push a tag and create a GitHub release. The `bottle.yml` workflow builds and uploads a bottle automatically.

```bash
git tag v1.0.0
git push origin v1.0.0
gh release create v1.0.0 --generate-notes
```

**Manual (local):**

```bash
./scripts/create-bottle.sh 1.0.0
# Upload the .tar.gz to the GitHub release
# Paste the bottle block into Formula/piqley.rb
```

## License

[GPLv3](LICENSE)
