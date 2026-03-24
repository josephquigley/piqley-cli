# Interactive Rules Command Resolution

## Problem

`piqley plugin rules` requires at least one argument (plugin identifier). If the user doesn't know the exact plugin ID or forgets the workflow name, they get an unhelpful ArgumentParser error. The command should resolve missing arguments interactively using TUI menus, reusing the same terminal primitives as the existing rules editor.

## Scope

All changes are in `PluginRulesCommand.swift`. No new files. No changes to PiqleyCore or PiqleyPluginSDK.

## Design

### Argument changes

`firstArg` becomes optional:

```swift
@Argument(help: "The plugin identifier (or workflow name if two arguments given).")
var firstArg: String?
```

`secondArg` remains unchanged.

### Resolution flow

`resolveArguments()` returns `(workflowName: String, pluginID: String)` as before. The logic branches on how many arguments are provided:

**Two args (workflow + plugin):**
Unchanged. Validate that the workflow exists and the plugin is in its pipeline. Error if not.

**One arg, matches a workflow name** (`WorkflowStore.exists(name:)`):
Load the workflow. Extract unique plugin identifiers from its pipeline. If exactly one plugin, auto-select it. If multiple, show a TUI selection menu. If the pipeline has no plugins, error.

**One arg, matches a plugin ID** (plugin directory exists):
Load all workflows. Filter to those whose pipeline contains the plugin. If exactly one, auto-select. If multiple, show a filtered TUI workflow selection menu (only workflows containing that plugin). If none contain the plugin, error.

**One arg, matches neither:**
Error: "'\(firstArg)' is not a known workflow or installed plugin."

**No args:**
Load all workflows. If exactly one, auto-select. If multiple, show a TUI workflow selection menu. Then extract unique plugin identifiers from the selected workflow's pipeline. If exactly one, auto-select. If multiple, show a TUI plugin selection menu. If none, error.

### TUI integration

Create a `RawTerminal` instance for selection menus. Use `selectFromList(title:items:)` which handles arrow keys, enter, and escape. If the user presses Escape from any selection menu, exit cleanly (throw `ExitCode.success`).

The terminal instance is only created when interactive selection is needed. When all arguments resolve without interaction, no terminal is created (preserving non-interactive compatibility).

**Non-interactive guard:** If stdin is not a TTY (`isatty(STDIN_FILENO) == 0`) and interactive selection would be needed, throw a `CleanError` with usage guidance instead of attempting TUI menus.

**RawTerminal lifecycle:** The `RawTerminal` used for menu selection must be fully destroyed (restored) before `RulesWizard` runs, since `RulesWizard.init()` creates its own `RawTerminal`. Create it in a limited scope within `resolveArguments`, not as stored state.

### Helper method

```swift
private func pipelinePlugins(_ workflow: Workflow) -> [String] {
    Array(Set(workflow.pipeline.values.flatMap(\.self))).sorted()
}
```

### Argument precedence

When one arg is provided, check workflow name first (`WorkflowStore.exists`), then plugin directory. This matches the mental model: if a name collides, the user can always disambiguate with two args.

### Error cases

| Scenario | Error |
|---|---|
| `rules <workflow> <plugin>` where plugin not in workflow | "Plugin '\(pluginID)' is not in workflow '\(workflowName)'" |
| `rules <unknown>` | "'\(arg)' is not a known workflow or installed plugin." |
| No workflows exist | "No workflows found. Run 'piqley setup' first." |
| Workflow has no plugins in pipeline | "Workflow '\(name)' has no plugins in its pipeline." |
| Plugin not in any workflow | "Plugin '\(id)' is not in any workflow's pipeline." |

### Existing behavior preserved

When both arguments are provided explicitly, the command behaves identically to today. The `run()` method body (loading manifest, stages, building context, launching RulesWizard) is unchanged.
