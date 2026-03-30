# Process Lock Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `piqley process` wait for an existing instance to finish instead of exiting immediately, with a configurable timeout.

**Architecture:** Add a retry loop with 5-second intervals to `ProcessLock`, a `--lock-timeout` CLI option to `ProcessCommand`, and a time formatting helper for the waiting message.

**Tech Stack:** Swift, ArgumentParser, Foundation (`flock`, `Task.sleep`)

---

### Task 1: Add time formatting helper and `.timedOut` error to ProcessLock

**Files:**
- Modify: `Sources/piqley/ProcessLock.swift`
- Test: `Tests/piqleyTests/ProcessLockTests.swift`

- [ ] **Step 1: Write failing tests for time formatting**

Add to `Tests/piqleyTests/ProcessLockTests.swift`:

```swift
func testFormatDurationMinutesOnly() {
    XCTAssertEqual(ProcessLock.formatDuration(seconds: 600), "10 minutes")
}

func testFormatDurationMinutesAndSeconds() {
    XCTAssertEqual(ProcessLock.formatDuration(seconds: 150), "2 minutes 30 seconds")
}

func testFormatDurationSecondsOnly() {
    XCTAssertEqual(ProcessLock.formatDuration(seconds: 30), "30 seconds")
}

func testFormatDurationOneMinute() {
    XCTAssertEqual(ProcessLock.formatDuration(seconds: 60), "1 minute")
}

func testFormatDurationOneSecond() {
    XCTAssertEqual(ProcessLock.formatDuration(seconds: 1), "1 second")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProcessLockTests`
Expected: FAIL — `formatDuration` does not exist yet.

- [ ] **Step 3: Implement `formatDuration` and add `.timedOut` error case**

In `Sources/piqley/ProcessLock.swift`, add the static method to `ProcessLock`:

```swift
static func formatDuration(seconds: Int) -> String {
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    var parts: [String] = []
    if minutes > 0 {
        parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
    }
    if remainingSeconds > 0 {
        parts.append("\(remainingSeconds) second\(remainingSeconds == 1 ? "" : "s")")
    }
    return parts.joined(separator: " ")
}
```

Add `.timedOut` to `ProcessLockError`:

```swift
case timedOut(seconds: Int)
```

Update `errorDescription`:
```swift
case let .timedOut(seconds):
    "Timed out after \(ProcessLock.formatDuration(seconds: seconds)) waiting for another instance to finish"
```

Update `failureReason`:
```swift
case .timedOut: "The lock was not released within the specified timeout."
```

Update `recoverySuggestion`:
```swift
case .timedOut: "Check if the other instance is still running, or remove the stale lock file if the previous run crashed."
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProcessLockTests`
Expected: All PASS.

- [ ] **Step 5: Commit**

```
feat: add time formatting helper and timedOut error to ProcessLock
```

---

### Task 2: Add `acquire(path:timeout:)` method

**Files:**
- Modify: `Sources/piqley/ProcessLock.swift`
- Test: `Tests/piqleyTests/ProcessLockTests.swift`

- [ ] **Step 1: Write failing test for acquire with no contention**

Add to `Tests/piqleyTests/ProcessLockTests.swift`:

```swift
func testAcquireSucceedsImmediately() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let lockPath = tmpDir.appendingPathComponent("test.lock").path
    let lock = try await ProcessLock.acquire(path: lockPath, timeout: 10)
    lock.release()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProcessLockTests/testAcquireSucceedsImmediately`
Expected: FAIL — `acquire` does not exist yet.

- [ ] **Step 3: Implement `acquire(path:timeout:)`**

Add to `ProcessLock` in `Sources/piqley/ProcessLock.swift`:

```swift
static func acquire(path: String, timeout: Int) async throws -> ProcessLock {
    let logger = Logger(label: "piqley.lock")
    var elapsed = 0
    var printed = false

    while true {
        do {
            return try ProcessLock(path: path)
        } catch ProcessLockError.alreadyRunning {
            if elapsed >= timeout {
                throw ProcessLockError.timedOut(seconds: timeout)
            }
            if !printed {
                printed = true
                logger.info(
                    "Another instance is running, waiting up to \(formatDuration(seconds: timeout))..."
                )
            }
            try await Task.sleep(for: .seconds(5))
            elapsed += 5
        }
    }
}
```

Add `import Logging` at the top of `ProcessLock.swift` if not already present.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProcessLockTests/testAcquireSucceedsImmediately`
Expected: PASS.

- [ ] **Step 5: Write failing test for acquire timeout**

Add to `Tests/piqleyTests/ProcessLockTests.swift`:

```swift
func testAcquireTimesOut() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("piqley-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let lockPath = tmpDir.appendingPathComponent("test.lock").path
    let holder = try ProcessLock(path: lockPath)
    defer { holder.release() }

    do {
        _ = try await ProcessLock.acquire(path: lockPath, timeout: 1)
        XCTFail("Expected timedOut error")
    } catch ProcessLockError.timedOut {
        // expected
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter ProcessLockTests/testAcquireTimesOut`
Expected: PASS — the lock is held, timeout is 1 second (shorter than the 5s interval, so it times out on the first retry check).

- [ ] **Step 7: Commit**

```
feat: add ProcessLock.acquire with retry loop and timeout
```

---

### Task 3: Add `--lock-timeout` option to ProcessCommand

**Files:**
- Modify: `Sources/piqley/CLI/ProcessCommand.swift`

- [ ] **Step 1: Add the `--lock-timeout` option**

Add to `ProcessCommand` alongside the other flags/options:

```swift
@Option(help: "Seconds to wait for another instance to finish (default: 600)")
var lockTimeout: Int = 600
```

- [ ] **Step 2: Replace `ProcessLock(path:)` with `ProcessLock.acquire`**

Change lines 46-48 in `ProcessCommand.run()` from:

```swift
let lockPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(PiqleyPath.lock).path
let lock = try ProcessLock(path: lockPath)
```

to:

```swift
let lockPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(PiqleyPath.lock).path
let lock = try await ProcessLock.acquire(path: lockPath, timeout: lockTimeout)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```
feat: add --lock-timeout option to process command
```
