# Architecture Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create comprehensive architecture documentation for the piqley ecosystem with mermaid diagrams, organized as progressive disclosure across 7 markdown files.

**Architecture:** Seven documents in `docs/architecture/` using tiered progressive disclosure. `overview.md` is the entry point linking to 5 detailed docs, which link to `file-layout.md` as the reference layer. All diagrams use mermaid syntax. Writing style matches existing docs: conversational, second-person, sentence-case headings, no em dashes.

**Tech Stack:** Markdown, Mermaid diagram syntax

**Source material:** Git history and changelogs from piqley-cli, piqley-core, and piqley-plugin-sdk repos. Current codebase structure.

**Style guide (derived from existing docs):**
- H1 for title only, H2/H3/H4 for sections
- Conversational, second-person tone ("your plugin", "you need to")
- Tables for reference material
- Inline code for paths, flags, field names
- Cross-references as relative markdown links: `[Link text](other-doc.md)`
- No em dashes; use colons, periods, commas
- Sentence case headings

---

## File structure

All files created in `docs/architecture/`:

| File | Responsibility |
|------|---------------|
| `overview.md` | Entry point: system diagram, pipeline summary, concept glossary, links to all other docs |
| `pipeline.md` | Pipeline orchestration, stage hooks, image flow, temp folder, fork manager, dry-run, process lock |
| `plugin-system.md` | Plugin lifecycle, discovery, communication protocol, manifest, SDK abstractions, packaging, binary probe |
| `rules-and-state.md` | State store, rule compilation, emit actions, rule slots, templates, auto-clone, skip propagation |
| `config-and-workflows.md` | Config resolution chain, workflow model, secrets, stage registry, pipeline editor |
| `cli-commands.md` | Command tree, wizard system, terminal management, interactive vs non-interactive |
| `file-layout.md` | Directory trees, JSON schema summaries, env var reference, exit codes, image formats |

---

### Task 1: Create `overview.md`

**Files:**
- Create: `docs/architecture/overview.md`

- [ ] **Step 1: Write `overview.md`**

```markdown
# Architecture overview

Piqley is a plugin-driven photographer workflow engine. It processes batches of images through a configurable pipeline of stages, where plugins perform work (tagging, resizing, publishing) and declarative rules transform metadata between stages. The system is split across three repositories that form a layered dependency chain.

## System layers

` ` `mermaid
graph TB
    subgraph "External"
        P1[Your plugin]
        P2[Another plugin]
    end

    subgraph "piqley-cli"
        CLI[CLI commands]
        ORCH[Pipeline orchestrator]
        WIZARD[TUI wizards]
        DISC[Plugin discovery]
        RULES[Rule evaluator]
        STATE[State store]
    end

    subgraph "piqley-plugin-sdk"
        PROTO[PiqleyPlugin protocol]
        REG[HookRegistry]
        REQ[PluginRequest / PluginResponse]
        SSTATE[PluginState / ResolvedState]
        BUILD[Packager / piqley-build]
    end

    subgraph "piqley-core"
        MANIFEST[PluginManifest]
        HOOK[Hook protocol / StandardHook]
        RULE[Rule / EmitConfig / MatchConfig]
        STAGE[StageConfig / StageRegistry]
        PAYLOAD[PluginInputPayload / PluginOutputLine]
        JSON[JSONValue / SemanticVersion]
    end

    P1 & P2 --> PROTO
    CLI --> ORCH
    CLI --> WIZARD
    ORCH --> DISC
    ORCH --> RULES
    ORCH --> STATE
    PROTO --> REG
    PROTO --> REQ
    REQ --> SSTATE
    DISC --> MANIFEST
    RULES --> RULE
    ORCH --> STAGE
    ORCH --> PAYLOAD
    PROTO --> HOOK
    REG --> HOOK
    BUILD --> MANIFEST
` ` `

**PiqleyCore** is the foundation library with no external dependencies. It defines the shared types that both the CLI and the SDK depend on: plugin manifests, rules, stage configs, JSON payload schemas, and validation.

**PiqleyPluginSDK** builds on PiqleyCore to provide Swift bindings for plugin authors: the `PiqleyPlugin` protocol, hook registration, typed state access, and the `piqley-build` packager. Plugins written in other languages can skip the SDK and conform directly to the JSON stdin/stdout protocol.

**piqley-cli** is the user-facing tool. It discovers plugins, orchestrates the pipeline, evaluates rules, manages workflows and config, and provides the interactive TUI wizards.

## Pipeline at a glance

` ` `mermaid
graph LR
    IN[Source images] --> PS[pipeline-start]
    PS --> PRE[pre-process]
    PRE --> POST[post-process]
    POST --> PUB[publish]
    PUB --> PP[post-publish]
    PP --> PF[pipeline-finished]
    PF --> OUT[Processed images]

    style PS fill:#e8f5e9
    style PF fill:#e8f5e9
` ` `

Images enter at `pipeline-start` and flow through each stage in order. At every stage, the orchestrator runs each assigned plugin's **preRules**, then its **binary** (if any), then its **postRules**. Rules read and transform metadata in the state store; binaries do the heavy lifting (resize, upload, tag).

The green stages (`pipeline-start`, `pipeline-finished`) are required lifecycle hooks that always run. The middle stages are the default set, but users can add, remove, rename, and reorder custom stages via the stage registry.

## Key concepts

| Concept | Definition |
|---------|-----------|
| **Stage** | A named step in the pipeline (e.g. `pre-process`, `publish`). Each stage has slots for preRules, a binary command, and postRules. |
| **Hook** | The protocol-level name a plugin recognizes. Usually matches the stage name, but custom stages can alias to a standard hook. |
| **Plugin** | A package installed at `~/.config/piqley/plugins/<identifier>/` containing a manifest, stage configs, and optionally a binary. |
| **Rule** | A declarative match-and-action pair. Matches a metadata field pattern, then emits actions (add, remove, replace, skip, etc.) to transform state. |
| **Workflow** | A named pipeline configuration stored at `~/.config/piqley/workflows/<name>/`. Maps stages to plugin lists and holds per-plugin config overrides. |
| **Namespace** | A scoped bucket in the state store. Each plugin writes to its own namespace; `original` holds extracted image metadata. |
| **State store** | The in-memory, per-run data structure holding all metadata and plugin output, keyed by image, then namespace, then field. |

## Detailed documentation

Each subsystem has its own detailed doc:

- **[Pipeline execution](pipeline.md):** how images flow through stages, the orchestrator sequence, fork management, dry-run mode
- **[Plugin system](plugin-system.md):** plugin discovery, the communication protocol, manifest structure, the SDK, packaging
- **[Rules and state](rules-and-state.md):** the state store, rule evaluation, emit actions, templates, skip propagation
- **[Configuration and workflows](config-and-workflows.md):** config resolution, workflow model, secrets, the stage registry
- **[CLI commands](cli-commands.md):** command tree, the TUI wizard system, interactive vs non-interactive mode
- **[File layout and reference](file-layout.md):** directory structures, JSON schemas, environment variables, exit codes
```

Note: the triple-backtick mermaid fences above are shown with spaces for escaping in this plan. In the actual file, use real triple backticks with no spaces.

- [ ] **Step 2: Commit**

```
git add docs/architecture/overview.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: add architecture overview with system and pipeline diagrams"

---

### Task 2: Create `pipeline.md`

**Files:**
- Create: `docs/architecture/pipeline.md`

- [ ] **Step 1: Write `pipeline.md`**

Content should cover (reference the codebase for accuracy):

**Sections:**

1. **Introduction paragraph**: the pipeline is the core of piqley, orchestrated by `PipelineOrchestrator` in `Sources/piqley/Pipeline/PipelineOrchestrator.swift`.

2. **Orchestration sequence diagram** (mermaid sequence):
   - ProcessCommand calls PipelineOrchestrator.run()
   - Acquires process lock
   - Creates TempFolder, copies images
   - Extracts metadata to "original" namespace via MetadataExtractor
   - Validates plugin dependencies and binaries
   - For each active stage in registry order:
     - For each plugin assigned to that stage:
       - Evaluate preRules (RuleEvaluator)
       - Run binary via PluginRunner (if stage has one)
       - Evaluate postRules
       - Merge plugin state into StateStore
       - Apply write actions via MetadataWriter
   - Clean up temp folder
   - Return success/failure

3. **Stage hook lifecycle diagram** (mermaid flowchart):
   - Show the three slots within a stage: preRules -> binary -> postRules
   - Explain that preRules transform state before the binary sees it, the binary does work, and postRules transform the binary's output

4. **Standard hooks table**: list all 6 standard hooks with descriptions (pipeline-start, pre-process, post-process, publish, post-publish, pipeline-finished)

5. **Image flow section**: explain TempFolder copying images, MetadataExtractor reading EXIF/IPTC to populate "original" namespace, supported formats table

6. **Fork manager section**: explain ForkManager for COW image isolation per plugin, ImageConverter for format conversion, fork/DAG source resolution

7. **Dry-run mode section**: explain --dry-run flag threading through to plugins, how it short-circuits destructive operations

8. **Process lock section**: explain ProcessLock for single-instance enforcement

9. **Navigation footer**: links back to [Architecture overview](overview.md), forward to [Plugin system](plugin-system.md), [Rules and state](rules-and-state.md)

Read these source files for accuracy:
- `Sources/piqley/Pipeline/PipelineOrchestrator.swift`
- `Sources/piqley/Pipeline/PipelineOrchestrator+Helpers.swift`
- `Sources/piqley/Pipeline/TempFolder.swift`
- `Sources/piqley/Pipeline/ForkManager.swift`
- `Sources/piqley/Pipeline/ImageConverter.swift`
- `Sources/piqley/State/MetadataExtractor.swift`
- `Sources/piqley/Plugins/PluginRunner.swift`
- `Sources/piqley/CLI/ProcessCommand.swift`

- [ ] **Step 2: Commit**

```
git add docs/architecture/pipeline.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: add pipeline execution architecture with orchestration sequence diagram"

---

### Task 3: Create `plugin-system.md`

**Files:**
- Create: `docs/architecture/plugin-system.md`

- [ ] **Step 1: Write `plugin-system.md`**

**Sections:**

1. **Introduction**: plugins are the extensibility mechanism. They can be Swift packages using the SDK, or any language that speaks the JSON stdin/stdout protocol.

2. **Three-repo dependency diagram** (mermaid graph):
   - PiqleyCore at bottom
   - PiqleyPluginSDK and piqley-cli both depending on PiqleyCore
   - Plugins depending on PiqleyPluginSDK (optional, can use raw JSON protocol)

3. **Plugin types section**: static (declarative-only, manifest + stage files, no binary) vs mutable (has binary, can modify images and state, created via `piqley plugin init`)

4. **Plugin discovery flowchart** (mermaid):
   - CLI scans `~/.config/piqley/plugins/`
   - For each directory: load manifest.json, validate with ManifestValidator
   - Load stage-*.json files
   - Auto-register unknown stages into StageRegistry
   - Return LoadedPlugin array

5. **Communication protocol section** with sequence diagram (mermaid):
   - CLI builds PluginInputPayload (hook, imageFolderPath, config, secrets, state, flags)
   - Writes JSON to plugin stdin
   - Plugin reads, processes images
   - Plugin writes JSON lines to stdout: progress, imageResult (per-image), result (final)
   - CLI reads exit code: success/warning/critical ranges

6. **PluginInputPayload table**: list all fields with types and descriptions

7. **PluginOutputLine table**: list output line types with fields

8. **SDK abstractions section**: how PiqleyPlugin protocol maps to the raw protocol, HookRegistry for type-safe hook dispatch, PluginRequest/PluginResponse as typed wrappers, PluginState/ResolvedState for state management

9. **Manifest structure section**: key fields (identifier, name, type, config, dependencies, fields, supportedPlatforms, supportedFormats), validation rules

10. **Plugin packaging section**: piqley-build and BuildManifest, .piqleyplugin archive structure, platform-specific bin/data directories

11. **Binary probing section**: BinaryProbe using --piqley-info to detect SDK vs regular CLI tools

12. **Dependency validation section**: DependencyValidator checking plugin dependencies before pipeline runs

13. **Navigation footer**: links to [Architecture overview](overview.md), [Pipeline execution](pipeline.md), [Rules and state](rules-and-state.md), [File layout](file-layout.md)

Read these source files for accuracy:
- `Sources/piqley/Plugins/PluginDiscovery.swift`
- `Sources/piqley/Plugins/PluginRunner.swift`
- `Sources/piqley/Plugins/PluginManifest.swift`
- `Sources/piqley/Plugins/BinaryProbe.swift`
- `Sources/piqley/Plugins/ExitCodeEvaluator.swift`
- `Sources/piqley/State/DependencyValidator.swift`
- PiqleyCore: `Sources/PiqleyCore/Manifest/PluginManifest.swift`
- PiqleyCore: `Sources/PiqleyCore/Payload/PluginInputPayload.swift`
- PiqleyCore: `Sources/PiqleyCore/Payload/PluginOutputLine.swift`
- PiqleyPluginSDK: `swift/PiqleyPluginSDK/Plugin.swift`
- PiqleyPluginSDK: `swift/PiqleyPluginSDK/HookRegistry.swift`
- PiqleyPluginSDK: `swift/PiqleyPluginSDK/Request.swift`
- PiqleyPluginSDK: `swift/PiqleyPluginSDK/Response.swift`
- PiqleyPluginSDK: `swift/PiqleyPluginSDK/Packager.swift`

- [ ] **Step 2: Commit**

```
git add docs/architecture/plugin-system.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: add plugin system architecture with discovery and communication diagrams"

---

### Task 4: Create `rules-and-state.md`

**Files:**
- Create: `docs/architecture/rules-and-state.md`

- [ ] **Step 1: Write `rules-and-state.md`**

**Sections:**

1. **Introduction**: the rules engine is piqley's declarative metadata transformation system. Rules let you manipulate image metadata without writing code.

2. **State store diagram** (mermaid):
   - Three-level hierarchy: image filename -> namespace (plugin identifier or "original") -> key/value pairs
   - Show MetadataExtractor populating "original" namespace
   - Show plugins writing to their own namespace
   - Show rules reading across namespaces via qualified field names (namespace:field)

3. **State store internals section**: actor-based concurrency, `setNamespace()`, `mergeNamespace()`, `resolve()`, namespacing per image per plugin

4. **Rule structure section**: anatomy of a Rule (match + emit[] + write[]), MatchConfig (field, pattern, not), EmitConfig (action, field, values, replacements, source, not)

5. **Rule evaluation flowchart** (mermaid):
   - Compile rules: patterns -> TagMatchers, resolve namespaces
   - For each image:
     - For each rule:
       - If unconditional (no match): apply actions
       - If conditional: evaluate match against state
       - If matched (respecting `not` flag): apply emit actions to working namespace
     - Apply write actions to image file metadata via MetadataWriter

6. **Emit action reference table**: each action type with description, required fields, and before/after example:
   - `add`: adds values to a field (creates if absent)
   - `remove`: removes matching values from a field
   - `replace`: regex/glob find-and-replace on field values
   - `removeField`: removes entire field from namespace
   - `clone`: copies a field from another namespace
   - `skip`: marks image as skipped for downstream plugins
   - `writeBack`: writes field value back to image file metadata

7. **Rule slots section**: preRules (before binary), postRules (after binary). Explain positioning and when each is useful.

8. **Pattern matching section**: exact strings, `regex:` prefix for regex, `glob:` prefix for glob patterns. PatternPrefix constants.

9. **Template resolution section**: `{{namespace:field}}` syntax in add action values, TemplateResolver, how templates reference state from other plugins or `read:` namespace for file metadata

10. **Auto-clone section**: when remove/replace targets a field absent from the plugin's namespace, the evaluator auto-clones from the match source namespace first

11. **Skip propagation section**: SkipRecord type, how skipped images are tracked in StateStore, removed from working folder, excluded from state payloads, and propagated via the wire payload

12. **Navigation footer**: links to [Architecture overview](overview.md), [Pipeline execution](pipeline.md), [Plugin system](plugin-system.md), [File layout](file-layout.md)

Read these source files for accuracy:
- `Sources/piqley/State/StateStore.swift`
- `Sources/piqley/State/RuleEvaluator.swift`
- `Sources/piqley/State/RuleEvaluator+Actions.swift`
- `Sources/piqley/State/MetadataExtractor.swift`
- `Sources/piqley/State/MetadataWriter.swift`
- `Sources/piqley/State/MetadataBuffer.swift`
- `Sources/piqley/State/TagMatcher.swift`
- `Sources/piqley/State/TemplateResolver.swift`
- PiqleyCore: `Sources/PiqleyCore/Config/Rule.swift`
- PiqleyCore: `Sources/PiqleyCore/Validation/RuleValidator.swift`
- PiqleyCore: `Sources/PiqleyCore/Constants/PatternPrefix.swift`
- PiqleyCore: `Sources/PiqleyCore/Payload/SkipRecord.swift`

- [ ] **Step 2: Commit**

```
git add docs/architecture/rules-and-state.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: add rules and state management architecture with evaluation flowchart"

---

### Task 5: Create `config-and-workflows.md`

**Files:**
- Create: `docs/architecture/config-and-workflows.md`

- [ ] **Step 1: Write `config-and-workflows.md`**

**Sections:**

1. **Introduction**: piqley uses a layered configuration system. Plugin defaults are overridden by base config, which is overridden by workflow-scoped config.

2. **Config resolution diagram** (mermaid):
   - Plugin manifest defaults (ConfigEntry values)
   - -> Base plugin config (`~/.config/piqley/config/<plugin>/config.json`)
   - -> Workflow-scoped overrides (workflow.json `config` section)
   - -> ConfigResolver merges all layers
   - Secrets resolved from SecretStore, injected as PIQLEY_SECRET_* env vars
   - Config values injected as PIQLEY_CONFIG_* env vars

3. **Workflow model section**: Workflow struct (name, displayName, description, schemaVersion, pipeline, config). Pipeline as `[String: [String]]` mapping hook names to plugin identifier lists.

4. **Workflow model diagram** (mermaid):
   - Show a workflow containing pipeline stages pointing to plugin lists
   - Show config overrides per plugin

5. **WorkflowStore section**: file-based persistence at `~/.config/piqley/workflows/<name>/workflow.json`, rules stored in `rules/<plugin>/stage-*.json`, methods (load, save, list, clone, delete), auto-stage-registration via `scanAndRegisterStages()`

6. **Secret management section**: SecretStore protocol, KeychainSecretStore on macOS, FileSecretStore elsewhere, plugin-scoped secret keys, alias-based indirection in WorkflowPluginConfig

7. **Stage registry section**: StageRegistry at `~/.config/piqley/stages.json`, active vs available stages, auto-registration from stage files, required stage protection (pipeline-start, pipeline-finished), mutation methods (add, activate, deactivate, remove, reorder, rename), hook aliasing via `resolvedHook(for:)`

8. **PipelineEditor section**: validation for add/remove plugin operations, stage name validation against registry

9. **Navigation footer**: links to [Architecture overview](overview.md), [Pipeline execution](pipeline.md), [Plugin system](plugin-system.md), [File layout](file-layout.md)

Read these source files for accuracy:
- `Sources/piqley/Config/Workflow.swift`
- `Sources/piqley/Config/WorkflowStore.swift`
- `Sources/piqley/Config/BasePluginConfig.swift`
- `Sources/piqley/Config/BasePluginConfigStore.swift`
- `Sources/piqley/Config/ConfigResolver.swift`
- `Sources/piqley/Config/PipelineEditor.swift`
- `Sources/piqley/Secrets/` (all files)
- PiqleyCore: `Sources/PiqleyCore/Config/StageRegistry.swift`
- PiqleyCore: `Sources/PiqleyCore/Manifest/PluginManifest.swift` (ConfigEntry)

- [ ] **Step 2: Commit**

```
git add docs/architecture/config-and-workflows.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: add configuration and workflow architecture with resolution diagram"

---

### Task 6: Create `cli-commands.md`

**Files:**
- Create: `docs/architecture/cli-commands.md`

- [ ] **Step 1: Write `cli-commands.md`**

**Sections:**

1. **Introduction**: piqley uses Swift ArgumentParser for its CLI. Commands are organized into groups with subcommands.

2. **Command tree diagram** (mermaid graph):
   ```
   piqley
   ├── process [workflow] <folder>
   ├── workflow
   │   ├── list
   │   ├── create <name>
   │   ├── clone <source> <dest>
   │   ├── delete <name>
   │   ├── edit [name]
   │   ├── open [name]
   │   ├── add-plugin <workflow> <plugin>
   │   ├── remove-plugin <workflow> <plugin>
   │   ├── config <workflow> <plugin>
   │   ├── rules [workflow] [plugin]
   │   └── command [workflow] [plugin]
   ├── plugin
   │   ├── list
   │   ├── setup <plugin>
   │   ├── init
   │   ├── create
   │   ├── install <path-or-url>
   │   ├── update <plugin> <path-or-url>
   │   ├── uninstall <plugin>
   │   └── edit [plugin]
   ├── secret
   │   ├── set <key> <value>
   │   ├── delete <key>
   │   └── prune
   ├── setup
   ├── clear-cache
   └── uninstall
   ```
   Render this as a mermaid graph TD with subgraphs for each command group.

3. **Process command section**: flags (--dry-run, --debug, --delete-source-contents, --delete-source-folder, --overwrite-source, --non-interactive), workflow resolution logic

4. **Wizard system section**: explain the TUI wizard architecture

5. **Wizard navigation diagram** (mermaid flowchart):
   - ConfigWizard: stage list -> select stage -> plugin list for stage -> select plugin -> action menu (rules, command, activate/deactivate)
   - RulesWizard: stage select -> slot select (preRules/postRules) -> rule list -> add/edit/delete/reorder rules
   - Rule building flow: rule type selection -> field selection -> pattern entry -> action configuration -> value entry -> save

6. **Terminal management section**: Terminal struct managing raw mode via POSIX termios, alternate screen buffer, save/restore state, ANSI module for colors/styles

7. **Interactive vs non-interactive section**: --non-interactive flag skips prompts, drops invalid rules with warnings, useful for CI/scripting

8. **Setup flow section**: installs bundled plugins, seeds default workflow, opens workflow editor

9. **Navigation footer**: links to [Architecture overview](overview.md), [Configuration and workflows](config-and-workflows.md), [Rules and state](rules-and-state.md)

Read these source files for accuracy:
- `Sources/piqley/Piqley.swift`
- `Sources/piqley/CLI/ProcessCommand.swift`
- `Sources/piqley/CLI/WorkflowCommand.swift`
- `Sources/piqley/CLI/PluginCommand.swift`
- `Sources/piqley/CLI/SecretCommand.swift`
- `Sources/piqley/CLI/SetupCommand.swift`
- `Sources/piqley/Wizard/ConfigWizard.swift`
- `Sources/piqley/Wizard/RulesWizard.swift`
- `Sources/piqley/Wizard/Terminal.swift`
- `Sources/piqley/Wizard/ANSI.swift`

- [ ] **Step 2: Commit**

```
git add docs/architecture/cli-commands.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: add CLI commands and wizard system architecture"

---

### Task 7: Create `file-layout.md`

**Files:**
- Create: `docs/architecture/file-layout.md`

- [ ] **Step 1: Write `file-layout.md`**

**Sections:**

1. **Introduction**: piqley stores all configuration, plugins, and runtime data under `~/.config/piqley/`.

2. **Top-level directory tree** (annotated code block):
   ```
   ~/.config/piqley/
   ├── workflows/                    # Named workflow configurations
   │   └── <name>/
   │       ├── workflow.json         # Pipeline definition and config overrides
   │       └── rules/
   │           └── <plugin-id>/
   │               └── stage-*.json  # Per-plugin, per-stage rule files
   ├── plugins/                      # Installed plugins
   │   └── <identifier>/
   │       ├── manifest.json         # Plugin metadata and declarations
   │       ├── stage-*.json          # Built-in stage configs (immutable after install)
   │       ├── bin/                   # Plugin binaries
   │       ├── data/                  # Plugin data files
   │       └── logs/                  # Plugin logs
   │           └── execution.jsonl   # Execution log for idempotent processing
   ├── config/                       # Base plugin configurations
   │   └── <plugin-id>/
   │       └── config.json           # Values and secret aliases
   ├── stages.json                   # Stage registry (active + available)
   ├── secrets.json                  # File-based secret store (non-macOS)
   └── piqley.lock                   # Process lock file
   ```

3. **Plugin directory detail section**: explain manifest.json, stage files (immutable defaults from install), bin/ with platform subdirs, data/ for plugin working files, logs/ with execution.jsonl

4. **Workflow directory detail section**: explain workflow.json, rules/ as mutable copies of plugin stage files scoped to this workflow

5. **JSON schema summaries**: tables for each key JSON file:
   - **PluginManifest**: identifier, name, type, description, pluginSchemaVersion, pluginVersion, config[], dependencies[], fields[], supportedFormats[], supportedPlatforms[]
   - **StageConfig**: preRules[], binary (HookConfig), postRules[]
   - **Rule**: match? (field, pattern, not?), emit[] (action, field?, values?, replacements?, source?, not?), write[]
   - **Workflow**: name, displayName?, description?, schemaVersion, pipeline {}, config {}
   - **PluginInputPayload**: hook, imageFolderPath, pluginConfig, secrets, executionLogPath, dataPath, logPath, dryRun, debug, state, pluginVersion, lastExecutedVersion, pipelineRunId, skipped[]
   - **PluginOutputLine**: type (progress/imageResult/result), message?, filename?, status?, success?, error?, state?

6. **Environment variable reference table**:
   - `PIQLEY_CONFIG_<KEY>`: config values (uppercased key)
   - `PIQLEY_SECRET_<KEY>`: resolved secrets (uppercased key)
   - `PIQLEY_IMAGE_FOLDER_PATH`: working image folder
   - `PIQLEY_DRY_RUN`: "true" or "false"
   - `PIQLEY_DEBUG`: "true" or "false"
   - `PIQLEY_PIPELINE_RUN_ID`: UUID for the current run
   - `PIQLEY_HOOK`: current stage hook name
   - `PIQLEY_DATA_PATH`: plugin data directory
   - `PIQLEY_LOG_PATH`: plugin log directory
   - `PIQLEY_EXECUTION_LOG_PATH`: execution log file
   - Custom env mappings from HookConfig.environment

7. **Exit code reference table**:
   - Success codes (default: 0)
   - Warning codes (configurable per plugin)
   - Critical codes (configurable per plugin, default: non-zero)

8. **Supported image formats table**: jpg, jpeg, png, tiff, tif, heic, heif, webp, jxl

9. **Navigation footer**: links to [Architecture overview](overview.md) and all other docs

Read these source files for accuracy:
- `Sources/piqley/Constants/PiqleyPath.swift`
- `Sources/piqley/Constants/PluginEnvironment.swift`
- `Sources/piqley/Plugins/ExitCodeEvaluator.swift`
- `Sources/piqley/Pipeline/TempFolder.swift` (supported formats)
- `Sources/piqley/Config/WorkflowStore.swift` (directory structure)
- PiqleyCore: `Sources/PiqleyCore/Constants/PluginFile.swift`
- PiqleyCore: `Sources/PiqleyCore/Constants/PluginDirectory.swift`
- PiqleyCore: `Sources/PiqleyCore/Manifest/HookConfig.swift` (exit codes, environment)
- PiqleyCore: `Sources/PiqleyCore/Payload/PluginInputPayload.swift`

- [ ] **Step 2: Commit**

```
git add docs/architecture/file-layout.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: add file layout and reference documentation"

---

### Task 8: Update existing docs with architecture links

**Files:**
- Modify: `docs/getting-started.md`
- Modify: `docs/plugin-sdk-guide.md`
- Modify: `docs/advanced-topics.md`

- [ ] **Step 1: Add "Further reading" or "Architecture" links to existing docs**

Add a link to the architecture overview from each existing doc's navigation/further reading section. For example, append to the end of each file (or to an existing "Further reading" section):

```markdown
- [Architecture overview](architecture/overview.md) - system diagrams, pipeline flow, and detailed subsystem documentation
```

- [ ] **Step 2: Commit**

```
git add docs/getting-started.md docs/plugin-sdk-guide.md docs/advanced-topics.md
git commit -F /tmp/commit-msg.txt
```

Commit message: "docs: link existing docs to architecture overview"
