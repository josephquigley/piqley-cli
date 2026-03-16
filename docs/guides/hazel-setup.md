# Setting Up Hazel with quigsphoto-uploader

This guide covers configuring Hazel to automatically invoke `quigsphoto-uploader` when Lightroom exports land in a watched folder.

## Overview

The workflow is: Lightroom exports photos to a folder, Hazel detects the new files, and Hazel runs `quigsphoto-uploader process` on that folder. Result files tell Hazel what happened so it can handle cleanup.

## Creating the Hazel Rule

### Watch Folder

Set Hazel to watch the folder where Lightroom exports photos. This is whatever folder you configured as your Lightroom export destination.

### File Type Filter

Configure the rule to match files with these extensions (case-insensitive):

- `.jpg`
- `.jpeg`
- `.jxl`

In Hazel, this looks like: **If all of the following conditions are met: Extension is jpg OR jpeg OR jxl**.

### Action: Run quigsphoto-uploader

Set the rule action to **Run shell script** with the following:

```bash
/usr/local/bin/quigsphoto-uploader process "$1"
```

Replace `/usr/local/bin/quigsphoto-uploader` with the actual install path of the binary. `$1` is the path to the matched file's parent folder.

If you want Hazel to pass the folder path rather than individual file paths, you can instead configure a folder-level rule or use a wrapper script:

```bash
#!/bin/bash
EXPORT_FOLDER="/path/to/lightroom/exports"
/usr/local/bin/quigsphoto-uploader process "$EXPORT_FOLDER"
```

Save this as a script (e.g., `~/scripts/run-quigsphoto-uploader.sh`), make it executable (`chmod +x`), and point the Hazel action at it.

### Exit Code Handling

`quigsphoto-uploader` uses these exit codes:

- **0** -- all images processed successfully.
- **1** -- fatal error (missing config, API unreachable, etc.). Nothing was processed.
- **2** -- partial success. Some images had errors, but others were processed.

You can use Hazel's "if the script returns" conditions to handle these differently if needed.

## Handling Result Files

After processing, `quigsphoto-uploader` writes plain-text result files to the input folder (one filename per line). Files are only created when they have entries.

| File | Meaning |
|------|---------|
| `.quigsphoto-uploader-success.txt` | Images that were uploaded successfully. Only written if `--verbose-results` is passed. |
| `.quigsphoto-uploader-failure.txt` | Images that had errors during processing. |
| `.quigsphoto-uploader-duplicate.txt` | Images skipped because they already exist in Ghost. |

### Recommended Hazel Rules for Result Files

Create additional Hazel rules in the same watched folder to react to these files:

**On success (cleanup exports):**
- Condition: Name is `.quigsphoto-uploader-success.txt`
- Action: Read filenames from the file, move the listed images to Trash (or an archive folder), then delete the result file.

**On failure (alert):**
- Condition: Name is `.quigsphoto-uploader-failure.txt`
- Action: Display a notification or move the failed images to a review folder.

**On duplicate (cleanup):**
- Condition: Name is `.quigsphoto-uploader-duplicate.txt`
- Action: Move duplicate images to Trash, then delete the result file.

Since these are dot-prefixed files, make sure Hazel is configured to see hidden files (Hazel handles this by default when you specify the exact filename).

## Serializing Invocations

`quigsphoto-uploader` acquires an advisory file lock at `<system-temp>/quigsphoto-uploader/quigsphoto-uploader.lock` on startup. If a second instance tries to run while the first is still active, it will exit immediately with an error. The lock is automatically released when the process exits, even on crash.

While the lock prevents actual conflicts, it is better to avoid the noise of failed lock attempts. To serialize at the Hazel level:

- **Use a single rule** that triggers on any matching file in the folder. Do not create multiple rules that each invoke `quigsphoto-uploader` -- Hazel may run them in parallel.
- **Set the rule to run once per folder** rather than once per file, if your Hazel version supports this. Since `quigsphoto-uploader process` takes a folder path and processes all images in it, one invocation covers everything.
- **Add a delay** if Lightroom exports files one at a time. A short pause (e.g., "If the file has not been modified for 30 seconds") lets the full export batch land before quigsphoto-uploader runs.

## Using --results-dir

By default, result files are written to the input folder. If you want them elsewhere (for example, a dedicated folder that Hazel watches for result-based automation), pass `--results-dir`:

```bash
/usr/local/bin/quigsphoto-uploader process /path/to/exports --results-dir /path/to/results
```

Then create your result-handling Hazel rules on the `--results-dir` folder instead of the export folder. This keeps the export folder clean and separates concerns.
