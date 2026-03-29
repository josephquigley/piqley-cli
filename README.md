<p align="center">
  <img src="logo.svg" alt="piqley" width="460"/>
</p>

<h1 align="center">piqley</h1>

<p align="center">
  A plugin-driven photographer workflow engine for macOS and Linux.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0"/>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey" alt="macOS | Linux"/>
  <img src="https://img.shields.io/github/license/josephquigley/piqley-cli" alt="License"/>
  <img src="https://img.shields.io/badge/Fully_Dogfooded-Yes-brightgreen?labelColor=555" alt="Fully Dogfooded: Yes"/>
</p>
<p align="center">
  <a href="https://ko-fi.com/I3I2LL7Y1"><img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="ko-fi"/></a>
</p>
---

Piqley processes exported photos and publishes them to any service with an API or CLI: Ghost, WordPress, Squarespace, social media, or your own custom workflow.

Want to export full-resolution photos with all metadata but strip GPS and private tags before publishing? Piqley can do that. Want to use keyword metadata and IPTC tags to draft a social media post without typing anything, #AnalogFilmIsNotDead? Piqley can do that. Want to use different hashtags for different services? Piqley can do that. Under the hood, everything is a [plugin](#plugin-system). Mix and match first-party and custom plugins into a pipeline that fits your workflow.

It works with any photo editor that exports to a folder (Lightroom, Capture One, Apple Photos, darktable, RawTherapee, etc.) and pairs well with [Hazel](https://www.noodlesoft.com) on macOS or any folder-watching automation for a fully hands-off workflow.

## Installation

```bash
brew tap quigs/tools https://github.com/josephquigley/piqley-cli.git
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
| `piqley process [workflow] <path>` | Process and publish photos (workflow name required when multiple exist) |
| `piqley plugin list` | List all installed plugins with active/inactive status |
| `piqley plugin setup [name]` | Configure a specific plugin (use `--force` to re-run setup) |
| `piqley plugin init [id] [name]` | Create a new declarative-only plugin interactively |
| `piqley plugin create <dir>` | Scaffold a new plugin project from an SDK skeleton |
| `piqley plugin install <file>` | Install a `.piqleyplugin` package (`--force` to overwrite) |
| `piqley workflow rules [workflow] <plugin>` | Interactive rule editor for a plugin's declarative metadata rules |
| `piqley workflow command [workflow] <plugin>` | Edit binary command configuration for a plugin's stages |
| `piqley secret set <key>` | Store a secret in the macOS Keychain |
| `piqley secret delete <key>` | Remove a secret from the Keychain |
| `piqley clear-cache` | Clear plugin execution logs (`--plugin <name>` for a specific plugin) |
| `piqley workflow edit [name]` | Edit a workflow interactively (lists all workflows if name omitted) |
| `piqley workflow create [name]` | Create a new workflow |
| `piqley workflow clone <src> <dst>` | Clone an existing workflow |
| `piqley workflow delete <name>` | Delete a workflow (`--force` to skip prompt) |
| `piqley workflow open <name>` | Open a workflow file in your editor |
| `piqley workflow add-plugin <workflow> <plugin> <stage>` | Add a plugin to a workflow stage |
| `piqley workflow remove-plugin <workflow> <plugin> <stage>` | Remove a plugin from a workflow stage |
| `piqley uninstall` | Remove all piqley configuration and plugins (`--force` to skip prompt) |

### Process Options

- `--dry-run` - Preview actions without uploading
- `--delete-source-contents` - Delete the contents of the source folder after a successful run
- `--delete-source-folder` - Delete the source folder and its contents after a successful run
- `--overwrite-source` - Overwrite source images with processed versions after a successful run
- `--non-interactive` - Skip interactive prompts; drop invalid rules with warnings

## Plugin System

Piqley's core is a lightweight orchestrator. All real work (image processing, uploading, scheduling) is handled by plugins running as isolated subprocesses. Piqley copies images into a temporary folder before the pipeline runs, plugins operate on those copies, and the processed results are copied back over the originals when the pipeline completes. The temp folder is automatically cleaned up.

### How Plugins Work

A plugin is a directory inside `~/.config/piqley/plugins/<plugin-name>/` containing a `manifest.json` and an executable. Write plugins in any language: Swift, Python, Go, Bash, or anything else that can read JSON from stdin and write JSON lines to stdout.

```
~/.config/piqley/plugins/my-plugin/
├── manifest.json           # Declarative: config schema, dependencies, supported platforms
├── config.json             # Mutable: resolved values (managed by piqley)
├── stage-pre-process.json  # Rules for pre-process hook
├── stage-post-process.json # Rules for post-process hook
├── data/                   # Plugin working directory
└── bin/                    # Plugin executables (platform-specific at build time, flattened on install)
```

Plugins support multiple platforms. A `.piqleyplugin` package can bundle binaries for `macos-arm64`, `linux-amd64`, and `linux-arm64`. When you install a plugin, piqley copies only the binaries for your platform.

### Pipeline

Plugins register for hooks in a four-stage pipeline:

| Hook | Purpose |
|------|---------|
| `pre-process` | Modify images before processing (e.g. watermarking) |
| `post-process` | Modify images after processing (e.g. resize, metadata) |
| `publish` | Upload or distribute processed images |
| `post-publish` | Clean up, notify, or log after publishing |

Workflows are stored in `~/.config/piqley/workflows/` as named JSON files. Each workflow defines its own pipeline. `piqley setup` creates a default workflow.

```json
{
  "name": "default",
  "displayName": "Default Workflow",
  "description": "Main photo processing workflow",
  "schemaVersion": 1,
  "pipeline": {
    "pre-process": ["privacy-strip", "ghost-tagger"],
    "publish": ["ghost-publisher"]
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
- Xcode 16+ or Swift 6.0+ toolchain

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
