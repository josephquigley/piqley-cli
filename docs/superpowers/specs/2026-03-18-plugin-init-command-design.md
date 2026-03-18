# Plugin Init Command Design

## Summary

Add `piqley plugin init` to scaffold declarative-only plugins — plugins that use metadata rules without a binary executable. This lets users quickly start mapping image metadata fields to tags without writing code.

## Command Signature

```
piqley plugin init [name] [--no-examples] [--non-interactive]
```

## Modes

### Interactive (default)

Prompts for:
1. Plugin name
2. Which hook to target (from canonical hook list)

Generates `manifest.json` and `config.json` with an example rule. If the chosen hook is not `pre-process`, the example rule includes `"hook": "<chosen-hook>"` in the match config.

### Interactive + `--no-examples`

Same prompts as interactive mode, but `config.json` contains an empty `rules` array.

### Non-interactive (`--non-interactive`)

Requires the `name` argument (errors if omitted). Generates:
- `manifest.json` with an empty `pre-process` hook
- `config.json` with an empty `rules` array

No example rules, no prompts.

## Generated Files

Written to `~/.config/piqley/plugins/<name>/`.

### `manifest.json`

```json
{
  "name": "<name>",
  "pluginProtocolVersion": "1",
  "hooks": {
    "<hook>": {}
  }
}
```

Empty hook config (no `command`) means the pipeline evaluates declarative rules but does not try to execute a binary.

### `config.json`

With examples:

```json
{
  "values": {},
  "rules": [
    {
      "match": { "field": "EXIF:Model", "pattern": "Canon EOS R5" },
      "emit": { "field": "tags", "values": ["Canon", "EOS R5"] }
    }
  ]
}
```

Without examples:

```json
{
  "values": {},
  "rules": []
}
```

## Validation

- Error if plugin directory already exists (prevents overwriting user work)
- In non-interactive mode, error if `name` argument is omitted
- Reject reserved name `"original"` (used internally by the state engine)
- Reject names with path separators, empty strings, or whitespace
- Create intermediate directories if `~/.config/piqley/plugins/` doesn't exist

## Implementation Location

Add `InitSubcommand` to `PluginCommand.swift`, registered in the `subcommands` array alongside `SetupSubcommand`.

## Scope

- No changes to PiqleyCore
- No changes to pipeline execution
- No changes to existing commands
