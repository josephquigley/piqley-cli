# Process Lock Timeout

## Summary

Replace the immediate-exit behavior of `ProcessLock` with a configurable wait-and-retry loop so that a second `piqley process` invocation waits for the first to finish instead of failing.

## Current Behavior

`ProcessLock.init` calls `flock(LOCK_EX | LOCK_NB)`. If the lock is held, it throws `.alreadyRunning` and the CLI exits immediately.

## New Behavior

### CLI Option

Add `--lock-timeout <seconds>` to `ProcessCommand` (default: 600). Accepts an integer number of seconds.

### Acquisition Loop

A new static method `ProcessLock.acquire(path:timeout:)`:

1. Attempt `flock(fd, LOCK_EX | LOCK_NB)`.
2. If it succeeds, return the lock.
3. On first failure, print: `"Another instance is running, waiting up to <formatted time>..."` to stderr via the logger.
4. Sleep 5 seconds, then retry from step 1.
5. If elapsed time exceeds the timeout, throw `.timedOut`.

The existing synchronous `init` stays available for non-waiting use cases.

### Time Formatting

Human-readable duration strings: "10 minutes", "5 minutes", "2 minutes 30 seconds", "30 seconds", etc. Only show non-zero components.

### Error Handling

Add a `.timedOut` case to `ProcessLockError` with a message like: "Timed out waiting for another instance to finish."

## Files Changed

- `Sources/piqley/ProcessLock.swift`: add `acquire(path:timeout:)`, `.timedOut` error case, time formatting helper
- `Sources/piqley/CLI/ProcessCommand.swift`: add `--lock-timeout` option, call `ProcessLock.acquire` instead of `ProcessLock(path:)`
- `Tests/piqleyTests/ProcessLockTests.swift`: update/add tests for timeout behavior
