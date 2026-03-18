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

Generates `manifest.json` and `config.json` with an example rule.

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
  "rules": [
    {
      "match": { "field": "EXIF:Model", "pattern": "exact:Canon EOS R5" },
      "emit": { "field": "tags", "values": ["Canon", "EOS R5"] }
    }
  ]
}
```

Without examples:

```json
{
  "rules": []
}
```

## Validation

- Error if plugin directory already exists (prevents overwriting user work)
- In non-interactive mode, error if `name` argument is omitted

## Implementation Location

Add `InitSubcommand` to `PluginCommand.swift`, registered in the `subcommands` array alongside `SetupSubcommand`.

## Scope

- No changes to PiqleyCore
- No changes to pipeline execution
- No changes to existing commands
