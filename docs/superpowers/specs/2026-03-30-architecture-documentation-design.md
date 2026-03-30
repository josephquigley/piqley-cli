# Architecture Documentation Design Spec

**Date:** 2026-03-30
**Audience:** Plugin authors and contributors
**Location:** `docs/architecture/` in piqley-cli

## Overview

Comprehensive architecture documentation for the piqley ecosystem using progressive disclosure across multiple markdown documents with mermaid diagrams. High-level overview links to detailed docs, which link to comprehensive reference material.

## Document Structure

```
docs/architecture/
├── overview.md              # Entry point: system diagram, component summary
├── pipeline.md              # Pipeline execution, stages, hooks, orchestration
├── plugin-system.md         # Plugin lifecycle, communication, manifest, discovery
├── rules-and-state.md       # Rule evaluation, state store, metadata flow
├── config-and-workflows.md  # Workflow model, config resolution, secrets
├── cli-commands.md          # Command tree, wizard system
└── file-layout.md           # Directory structure, JSON schemas, env vars
```

## Document Details

### 1. `overview.md`: Architecture Overview

The single entry point. Contains:

- One-paragraph project description (photographer workflow engine with plugin-driven pipeline)
- **System-level mermaid diagram**: shows the three repos (PiqleyCore, PluginSDK, CLI) as layers, with plugins as external actors. Arrows show dependency direction and data flow.
- **Simplified pipeline flow diagram**: mermaid flowchart showing images entering, flowing through stages (pipelineStart -> preProcess -> postProcess -> publish -> postPublish -> pipelineFinished), with plugins executing at each stage.
- Key concepts table mapping terms (stage, hook, rule, workflow, plugin, namespace) to brief definitions
- One-paragraph summary of each subsystem linking to its detailed doc

### 2. `pipeline.md`: Pipeline Execution

The core processing engine. Contains:

- **Pipeline orchestration sequence diagram**: mermaid sequence showing ProcessCommand -> PipelineOrchestrator -> TempFolder setup -> metadata extraction -> stage loop (for each stage, for each plugin: PluginRunner invocation -> rule evaluation -> state update -> metadata write)
- **Stage hook lifecycle diagram**: shows the six standard hooks in order, with preRules/binary/postRules slots within each stage
- **Image flow diagram**: images copied to temp folder, metadata extracted to "original" namespace, transformed through stages, output
- ForkManager and image branching/conversion
- Dry-run mode short-circuiting
- Process lock for concurrent run prevention
- Links: back to overview, forward to rules-and-state.md, plugin-system.md

### 3. `plugin-system.md`: Plugin System

Full plugin lifecycle across all three repos. Contains:

- **Three-repo dependency diagram**: PiqleyCore at base, PluginSDK and CLI both depending on it, plugins depending on PluginSDK (or just conforming to JSON protocol)
- **Plugin discovery flowchart**: CLI scans plugin directory -> loads manifest -> validates -> registers stages -> returns LoadedPlugin
- **Plugin communication sequence diagram**: CLI writes PluginInputPayload to stdin -> plugin processes -> plugin emits progress/imageResult lines on stdout -> plugin writes final result line -> CLI reads exit code
- Plugin types: static (declarative-only) vs mutable (has binary, can modify images/state)
- Manifest structure and validation
- SDK abstractions: PiqleyPlugin protocol, HookRegistry, PluginRequest/PluginResponse mapping to raw JSON protocol
- Plugin packaging with piqley-build
- Dependency validation and binary probing
- Links: pipeline.md for execution context, rules-and-state.md for output feeding rules

### 4. `rules-and-state.md`: Rules and State Management

Declarative metadata transformation system. Contains:

- **State store diagram**: three-level hierarchy (image -> namespace -> key/value). Shows metadata extraction populating "original", plugins writing to their namespace, rules reading across namespaces.
- **Rule evaluation flowchart**: compile rules -> for each image: check match -> if matched: apply emit actions -> apply write actions
- **Emit action reference diagram**: each action type (add, remove, replace, removeField, clone, skip, writeBack) with before/after state examples
- Rule slot positioning: preRules before binary, postRules after, writeRules modify file metadata
- Template resolution and pattern matching (regex:, glob: prefixes)
- Auto-clone for remove/replace on empty namespaces
- RuleEvaluatorCache optimization
- SkipRecord propagation
- Links: pipeline.md for when rules execute, plugin-system.md for consumed fields

### 5. `config-and-workflows.md`: Configuration and Workflows

Config resolution chain and workflow model. Contains:

- **Config resolution diagram**: merge chain from plugin manifest defaults -> base plugin config -> workflow-scoped overrides -> resolved config. Secrets resolved from SecretStore, injected as env vars.
- **Workflow model diagram**: workflow containing name, pipeline (hook -> plugin list), per-plugin config overrides
- WorkflowStore persistence (directory-based)
- Secret management: Keychain on macOS, file-based elsewhere, scoped by plugin identifier
- Stage registry: active vs available, auto-registration, required stage protection
- PipelineEditor validation
- Links: pipeline.md for config in execution, plugin-system.md for manifest config declarations

### 6. `cli-commands.md`: CLI Commands and Wizard System

CLI structure and interactive TUI. Contains:

- **Command tree diagram**: top-level piqley branching to subcommands (process, workflow, plugin, secret, setup, clear-cache, uninstall), each expanding to their subcommands
- **Wizard navigation diagram**: ConfigWizard flow (stage selector -> plugin list -> rules editor), RulesWizard sub-flow (stage select -> slot select -> rule list -> build/edit/delete)
- Terminal raw mode and alternate screen buffer management
- Interactive vs non-interactive mode
- Setup bootstrapping
- Links: config-and-workflows.md for what wizards edit, rules-and-state.md for rule building

### 7. `file-layout.md`: File Layout and Reference

Comprehensive reference layer. Contains:

- **Directory tree diagram**: annotated ~/.config/piqley/ layout with workflows/, plugins/, config/, secrets, stages.json, lock file
- Plugin directory structure: manifest.json, config.json, stage-*.json, bin/, data/, logs/
- Workflow directory structure: workflow.json, rules/plugin/stage-*.json
- JSON schema summaries: PluginManifest, StageConfig, Rule, Workflow, PluginInputPayload, PluginOutputLine
- Environment variable reference: PIQLEY_CONFIG_*, PIQLEY_SECRET_*, PIQLEY_IMAGE_FOLDER_PATH, PIQLEY_DRY_RUN, etc.
- Exit code reference
- Supported image formats
- Links: back to every other doc where relevant

## Design Principles

- **Progressive disclosure**: overview -> detailed -> reference. Each layer is self-contained but links deeper.
- **Mermaid diagrams**: all diagrams in mermaid syntax for GitHub rendering and portability.
- **Source of truth**: derived from current codebase, git history, and changelogs across all three repos.
- **Cross-linking**: every detailed doc links back to overview and forward to related docs.
- **Dual audience**: plugin authors get communication protocol and lifecycle docs; contributors get internal architecture and subsystem docs.
