# Getting Started with Piqley

Piqley is a rule and plugin-driven workflow engine for photographers. You export photos from your editor (Lightroom, Capture One, Apple Photos, darktable, etc.), point piqley at the folder, and plugins handle everything else: stripping private metadata, adding tags, resizing, publishing to your blog or social media, sending emails.

Everything is a plugin. Piqley's core is a lightweight orchestrator that copies your images into a temporary folder, runs plugins in order, then copies the processed results back over the originals.

## Install

```bash
brew tap quigs/tools https://github.com/josephquigley/piqley-cli.git
brew install quigs/tools/piqley
```

## First-Time Setup

```bash
piqley setup
```

This creates your config file and walks you through interactive configuration for any installed plugins.

## Process a Folder of Photos

```bash
piqley process /path/to/exported/photos
```

Piqley copies the images into a temp folder, runs every plugin in pipeline order, copies the processed images back, and prints the results.

### Useful flags

```bash
# Preview what would happen without modifying anything or executing anything
piqley process /path/to/photos --dry-run

# Delete the source folder contents after a successful run
# (useful with folder-watching automation like Hazel)
piqley process /path/to/photos --delete-source-contents
```

In dry run mode, plugins receive a `dryRun` flag and skip destructive operations (API calls, uploads, file writes) while reporting what they *would* do. This lets you verify your pipeline configuration before running it for real.

## How the Pipeline Works

Every plugin registers for one or more hooks in piqley's four-stage pipeline:

| Stage | When it runs | Typical use |
|-------|-------------|-------------|
| `pre-process` | Before anything else | Strip metadata, add watermarks, tag images |
| `post-process` | After pre-processing | Resize, format conversion, final metadata writes |
| `publish` | After processing is complete | Upload to Ghost, WordPress, email, social media |
| `post-publish` | After publishing | Cleanup, notifications, logging |

Plugins within a stage run in the order you configure them.

## Understanding Plugins

There are two kinds of plugins:

**Declarative plugins** use rules to match metadata patterns and take actions (add tags, remove fields, copy values between plugins, skip images from the pipeline). No code needed. You configure everything through the interactive rule editor.

**Binary plugins** are executables that receive image paths and metadata, do their work (API calls, resizing, complex logic), and stream results back. Write them in any language. The [plugin SDK](https://github.com/josephquigley/piqley-plugin-sdk) provides helpers for Swift, Python, Node.js, and Go.

Most real plugins combine both: declarative rules handle metadata before and after the binary runs.

## Creating Your First Plugin

The fastest way to create a declarative-only plugin (no code):

```bash
piqley plugin init
```

This walks you through naming and generates a plugin directory with example rules for each stage. Skip the examples with `--no-examples` if you want a blank slate.

To scaffold a full plugin project with an SDK skeleton:

```bash
piqley plugin create ~/Developer/my-piqley-plugin --language swift
```

## Editing Rules

The TUI rule editor lets you create, edit, reorder, and delete rules without touching any files by hand:

```bash
piqley workflow rules com.example.my-plugin
```

Features:
- Browse and reorder rules with keyboard shortcuts
- Autocomplete for metadata field names (press Ctrl+L for a filterable list)
- Live match context preview when selecting actions
- Save with `s`, quit with `q`, undo deletes before saving

## Managing Secrets

Plugins that call external APIs need credentials. Piqley stores these in the macOS Keychain:

```bash
# Store a secret
piqley secret set my-ghost-publisher admin-api-key

# Remove a secret
piqley secret delete my-ghost-publisher admin-api-key
```

Secrets are passed to plugins at runtime. They never touch disk as plaintext.

## Managing Plugins

```bash
# List all installed plugins
piqley plugin list

# Re-run setup for a specific plugin
piqley plugin setup my-plugin --force

# Install a packaged plugin
piqley plugin install path/to/plugin.piqleyplugin

# Update an installed plugin (preserves existing config values and secrets)
piqley plugin update path/to/plugin.piqleyplugin

# Set per-workflow config overrides
piqley workflow config my-workflow my-plugin
```

## Automating with Hazel

Piqley pairs well with [Hazel](https://www.noodlesoft.com) or any folder-watching tool. Set up a rule that watches your Lightroom export folder and runs:

```bash
piqley process "$1" --delete-source-contents --non-interactive
```

The `--non-interactive` flag skips prompts (dropping invalid rules with a warning instead of asking), and `--delete-source-contents` cleans up after a successful run. Fully hands-off.

## What's Next

- [Advanced Topics](advanced-topics.md) for real-world workflow examples, rule syntax, plugin composability patterns, and multi-publisher pipelines.
- [Plugin Development with the SDK](plugin-sdk-guide.md) for building binary plugins that call APIs, resize images, or run custom logic.
