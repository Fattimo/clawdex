# Pet Controls and Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add hover-revealed pet controls for resizing and opening a compact settings popover, with persisted message and switchboard visibility settings.

**Architecture:** Keep the pet window responsible for its hover controls and scale changes, while a small persisted config model owns user preferences. `SpeechController` receives config updates and gates bubbles or pills without changing the existing Claude/Codex state machine.

**Tech Stack:** Swift, AppKit, NSPanel, NSPopover, Codable JSON persistence, XCTest.

---

### Task 1: Persisted config model

**Files:**
- Create: `Sources/ClawdexApp/ClawdexConfig.swift`
- Test: `Tests/ClawdexAppTests/ClawdexConfigTests.swift`

- [ ] **Step 1: Write the failing config round-trip test**

```swift
func testConfigRoundTripsMessageVisibilitySwitchboardAndScale() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("clawdex-config-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: path) }

    var config = ClawdexConfig()
    config.messageVisibility = .finalOnly
    config.showSwitchboard = false
    config.petScale = 1.1
    try config.save(to: path)

    let loaded = try ClawdexConfig.load(from: path)
    XCTAssertEqual(loaded.messageVisibility, .finalOnly)
    XCTAssertFalse(loaded.showSwitchboard)
    XCTAssertEqual(loaded.petScale, 1.1, accuracy: 0.001)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ClawdexConfigTests/testConfigRoundTripsMessageVisibilitySwitchboardAndScale`

Expected: FAIL because `ClawdexConfig` does not exist yet.

- [ ] **Step 3: Write the minimal config implementation**

```swift
enum MessageVisibility: String, Codable, CaseIterable {
    case all
    case finalOnly
    case none
}

struct ClawdexConfig: Codable, Equatable {
    var messageVisibility: MessageVisibility = .all
    var showSwitchboard: Bool = true
    var petScale: CGFloat = 0.75

    static let defaultPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".clawdex/config.json")

    static func load(from path: URL = defaultPath) throws -> ClawdexConfig
    func save(to path: URL = defaultPath) throws
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ClawdexConfigTests/testConfigRoundTripsMessageVisibilitySwitchboardAndScale`

Expected: PASS.

### Task 2: Speech visibility behavior

**Files:**
- Modify: `Sources/ClawdexApp/SpeechController.swift`
- Test: `Tests/ClawdexAppTests/SpeechControllerTests.swift`

- [ ] **Step 1: Write failing visibility tests**

```swift
func testMessageVisibilityNoneSuppressesBubbles() throws {
    let pet = PetWindow()
    let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none, showSwitchboard: false))

    speech.handle(event: "Stop", narration: "done", transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    XCTAssertEqual(pet.childWindows?.count ?? 0, 0)
}

func testFinalOnlySuppressesNonFinalMessagesButShowsStop() throws {
    let pet = PetWindow()
    let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .finalOnly, showSwitchboard: false))

    speech.handle(event: "PreToolUse", narration: "working", transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(pet.childWindows?.count ?? 0, 0)

    speech.handle(event: "Stop", narration: "done", transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(pet.childWindows?.count ?? 0, 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SpeechControllerTests/testMessageVisibilityNoneSuppressesBubbles --filter SpeechControllerTests/testFinalOnlySuppressesNonFinalMessagesButShowsStop`

Expected: FAIL because `SpeechController` has no config-aware initializer.

- [ ] **Step 3: Add config-aware speech gating**

```swift
private var config: ClawdexConfig

init(pet: PetWindow, config: ClawdexConfig = ClawdexConfig()) {
    self.pet = pet
    self.config = config
}

func updateConfig(_ config: ClawdexConfig) {
    self.config = config
    if !config.showSwitchboard { removeAllPills() }
    if config.messageVisibility == .none { removeAllBubbles() }
}
```

Gate pill creation with `config.showSwitchboard`, and gate `show(...)` with:

```swift
switch config.messageVisibility {
case .all: break
case .finalOnly where isFinal: break
case .finalOnly, .none: return
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SpeechControllerTests/testMessageVisibilityNoneSuppressesBubbles --filter SpeechControllerTests/testFinalOnlySuppressesNonFinalMessagesButShowsStop`

Expected: PASS.

### Task 3: Pet hover controls and scale

**Files:**
- Modify: `Sources/ClawdexApp/PetWindow.swift`
- Test: `Tests/ClawdexAppTests/PetWindowTests.swift`

- [ ] **Step 1: Write the failing scale test**

```swift
func testPetScaleChangesFrameSize() {
    let pet = PetWindow(scale: 0.75)
    let initialWidth = pet.frame.width

    pet.setScale(1.0)

    XCTAssertGreaterThan(pet.frame.width, initialWidth)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PetWindowTests/testPetScaleChangesFrameSize`

Expected: FAIL because `setScale` does not exist yet.

- [ ] **Step 3: Add hover controls and resizing**

```swift
private var scale: CGFloat
var onSettings: ((NSView, NSRect) -> Void)?
var onScaleChanged: ((CGFloat) -> Void)?

func setScale(_ newScale: CGFloat) {
    let clamped = min(max(newScale, 0.5), 1.5)
    scale = clamped
    let size = NSSize(width: AnimationConstants.cellWidth * clamped,
                      height: AnimationConstants.cellHeight * clamped)
    setFrame(NSRect(origin: frame.origin, size: size), display: true)
    spriteLayer.frame = NSRect(origin: .zero, size: size)
    contentView?.frame = NSRect(origin: .zero, size: size)
    onMoved?()
}
```

Add a `PetControlsView` subview that appears while the pet is hovered, draws filled translucent gear and resize buttons in the bottom-right corner, calls `onSettings` from the gear button, and sends drag deltas from the resize button to `setScale`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PetWindowTests/testPetScaleChangesFrameSize`

Expected: PASS.

### Task 4: Settings popover wiring

**Files:**
- Create: `Sources/ClawdexApp/SettingsPopover.swift`
- Modify: `Sources/ClawdexApp/main.swift`
- Test: `Tests/ClawdexAppTests/SpeechControllerTests.swift`

- [ ] **Step 1: Add the settings popover**

```swift
final class SettingsPopover {
    var onChange: ((ClawdexConfig) -> Void)?
    func show(from view: NSView, rect: NSRect, config: ClawdexConfig)
}
```

The popover contains:

```swift
NSSegmentedControl(labels: ["All", "Final only", "None"], trackingMode: .selectOne, target: self, action: #selector(messageChanged))
NSSegmentedControl(labels: ["Yes", "No"], trackingMode: .selectOne, target: self, action: #selector(switchboardChanged))
```

- [ ] **Step 2: Wire app-level config updates**

```swift
private var config = (try? ClawdexConfig.load()) ?? ClawdexConfig()
private let settingsPopover = SettingsPopover()

window = PetWindow(scale: config.petScale)
speech = SpeechController(pet: window, config: config)
window.onScaleChanged = { [weak self] scale in
    self?.config.petScale = scale
    try? self?.config.save()
}
settingsPopover.onChange = { [weak self] config in
    self?.config = config
    try? config.save()
    self?.speech.updateConfig(config)
}
```

- [ ] **Step 3: Run the full test suite**

Run: `swift test`

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClawdexApp/ClawdexConfig.swift Sources/ClawdexApp/PetWindow.swift Sources/ClawdexApp/SettingsPopover.swift Sources/ClawdexApp/SpeechController.swift Sources/ClawdexApp/main.swift Tests/ClawdexAppTests/ClawdexConfigTests.swift Tests/ClawdexAppTests/PetWindowTests.swift Tests/ClawdexAppTests/SpeechControllerTests.swift
git commit -m "feat: add pet settings and resize controls"
```
