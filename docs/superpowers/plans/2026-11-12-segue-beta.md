# Segue Beta Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app that makes skipping a song in Apple Music a varied fade + EQ-sweep transition, and restores volume and EQ afterwards.

**Architecture:** A Swift package with a pure-logic library (`SegueCore`: recipes, fade curves, the transition engine, snapshot store) that talks to Music and the Equalizer only through two protocols, and an app target (`Segue`) holding the real controllers (ScriptingBridge for Music, Accessibility API for the Equalizer window), global hotkeys and the SwiftUI menu bar panel. The engine is an actor driven by an injectable clock so all rules are tested with fakes.

**Tech Stack:** Swift 6.1 toolchain (language mode 5), Swift Package Manager, Swift Testing, SwiftUI `MenuBarExtra`, ScriptingBridge, ApplicationServices (AX), Carbon hot keys, `SMAppService`. No Xcode, no third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-12-segue-beta-design.md`

## Global Constraints

- macOS 15 host; package platform `.macOS(.v14)`. Build and test with `swift build` / `swift test` from the repo root (Command Line Tools only).
- Apple Music's Music app only. Segue never touches audio; it only sets Music's volume, sends next/play/pause, and moves the Equalizer window's controls.
- Never use Music's scripted EQ properties (`EQ enabled`, `EQ preset`, `band N`): they do not affect live sound.
- EQ slider values are hundredths of a dB, −1200…1200. Bands are indexed 0…9 = 32, 64, 125, 250, 500 Hz, 1, 2, 4, 8, 16 kHz.
- Default shortcuts: ⌥⌘S (DJ skip), ⌥⌘P (faded pause/resume).
- Defaults: length range 3–8 s (limits 1–12), fade-in 1.5 s, pause fade 0.6 s, tick 1/30 s.
- After every transition, volume, EQ on/off, EQ preset and slider values equal what they were before it, unless the user changed the volume mid-transition.
- Commit after every task; end commit messages with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. Shortcut pressed again while the next song is fading in → volume ends at the saved level, never stuck partway (Task 5).
2. Pause shortcut pressed during a DJ skip → transition cancels without skipping, state restored, Music pauses (Task 6).
3. Equalizer call fails partway through a sweep → the fade finishes, the skip happens, no crash (Task 5).
4. Starting volume is 0 → skip still happens, volume ends at 0 (Task 4).
5. Length range saved with min > max, or outside 1–12 → picker clamps and swaps instead of crashing (Task 2).

---

## File Structure

```
Package.swift
Sources/SegueCore/
  Recipe.swift            FadeShape, EQFocus, Recipe, TransitionSettings
  FadeCurve.swift         shape → level; volume and band math
  RecipePicker.swift      random pick + no-repeat rule
  Controlling.swift       PlayerState, EQSnapshot, StateSnapshot, MusicControlling, EqualizerControlling, EngineClock
  SnapshotStore.swift     crash-recovery file
  TransitionEngine.swift  DJ skip, pause/resume, rules
Sources/Segue/
  MusicAppController.swift    ScriptingBridge → MusicControlling
  AXEqualizerController.swift Accessibility → EqualizerControlling
  HotkeyManager.swift         Carbon global hot keys
  SettingsStore.swift         UserDefaults-backed settings + shortcuts
  PanelView.swift             menu bar panel
  SegueApp.swift              @main, wiring, --probe mode
Tests/SegueCoreTests/
  Fakes.swift, FadeCurveTests.swift, RecipePickerTests.swift,
  SnapshotStoreTests.swift, EngineSkipTests.swift, EngineRulesTests.swift, EnginePauseTests.swift
scripts/build-app.sh, scripts/make-signing-cert.sh
README.md, LICENSE, docs/manual-checklist.md
```

---

### Task 1: Package, recipe types and fade math

**Files:**
- Create: `Package.swift`, `Sources/SegueCore/Recipe.swift`, `Sources/SegueCore/FadeCurve.swift`, `Sources/Segue/SegueApp.swift` (placeholder `@main` that prints "Segue"), `Tests/SegueCoreTests/FadeCurveTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum FadeShape: CaseIterable, Sendable { case earlyDrop, steady, lateDrop }
  public enum EQFocus: CaseIterable, Sendable { case none, lows, mids, highs, lowsAndHighs
      public var bandWeights: [Int: Double] { get } }   // band index → 0.5 or 1.0
  public struct Recipe: Equatable, Sendable {
      public var length: Double          // seconds
      public var fadeTarget: Double      // 0, 0.25, 0.45 or 0.6
      public var shape: FadeShape
      public var focus: EQFocus
      public var depth: Int }            // hundredths of dB, -1200...-600
  public struct TransitionSettings: Equatable, Sendable {
      public var minLength = 3.0, maxLength = 8.0
      public var variation = true, eqEffects = true
      public var fadeIn = 1.5
      public var fadeOnPause = true
      public static let pauseFade = 0.6
      public init() }
  public enum FadeCurve {
      public static func level(_ shape: FadeShape, progress: Double) -> Double
      public static func volume(start: Int, recipe: Recipe, progress: Double) -> Int
      public static func bands(original: [Int], recipe: Recipe, progress: Double) -> [Int: Int] }
  ```

- [ ] **Step 1: Write `Package.swift`** — swift-tools-version 6.0; `platforms: [.macOS(.v14)]`; targets `SegueCore` (library), `Segue` (executable, depends on `SegueCore`), `SegueCoreTests` (depends on `SegueCore`); `swiftLanguageModes: [.v5]`.

- [ ] **Step 2: Write the failing tests** in `FadeCurveTests.swift` (Swift Testing, `@testable import SegueCore`):

  ```swift
  @Test(arguments: FadeShape.allCases) func levelEndpoints(shape: FadeShape) {
      #expect(FadeCurve.level(shape, progress: 0) == 1)
      #expect(FadeCurve.level(shape, progress: 1) == 0)
      #expect(FadeCurve.level(shape, progress: 1.7) == 0)      // clamps
  }
  @Test(arguments: FadeShape.allCases) func levelNeverRises(shape: FadeShape) {
      let xs = stride(from: 0.0, through: 1.0, by: 0.01).map { FadeCurve.level(shape, progress: $0) }
      #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 >= $1 })
  }
  @Test func shapesDifferAtMidpoint() {
      #expect(FadeCurve.level(.earlyDrop, progress: 0.5) < FadeCurve.level(.steady, progress: 0.5))
      #expect(FadeCurve.level(.steady, progress: 0.5) < FadeCurve.level(.lateDrop, progress: 0.5))
  }
  @Test func volumeStopsAtFadeTarget() {
      let r = Recipe(length: 4, fadeTarget: 0.25, shape: .steady, focus: .none, depth: -1200)
      #expect(FadeCurve.volume(start: 80, recipe: r, progress: 0) == 80)
      #expect(FadeCurve.volume(start: 80, recipe: r, progress: 1) == 20)
      #expect(FadeCurve.volume(start: 0, recipe: r, progress: 0.5) == 0)
  }
  @Test func lowsCutMovesLowBandsOnly() {
      let r = Recipe(length: 4, fadeTarget: 0, shape: .steady, focus: .lows, depth: -1200)
      let orig = [Int](repeating: 100, count: 10)
      let end = FadeCurve.bands(original: orig, recipe: r, progress: 1)
      #expect(end == [0: -1200, 1: -1200, 2: -1200, 3: -1200, 4: -600])
      #expect(FadeCurve.bands(original: orig, recipe: r, progress: 0) == [0: 100, 1: 100, 2: 100, 3: 100, 4: 100])
  }
  @Test func focusWeights() {
      #expect(EQFocus.none.bandWeights.isEmpty)
      #expect(EQFocus.mids.bandWeights == [3: 0.5, 4: 1, 5: 1, 6: 1, 7: 0.5])
      #expect(EQFocus.highs.bandWeights == [6: 0.5, 7: 1, 8: 1, 9: 1])
      #expect(EQFocus.lowsAndHighs.bandWeights == [0: 1, 1: 1, 2: 1, 3: 1, 4: 0.5, 6: 0.5, 7: 1, 8: 1, 9: 1])
  }
  ```

- [ ] **Step 3: Run** `swift test` — Expected: FAIL (types not defined). If the runner itself errors with "no such module 'Testing'", rerun with `swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks` and record the working command in `README.md` under "Build".

- [ ] **Step 4: Implement `Recipe.swift` and `FadeCurve.swift`.** Formulas (p clamped to 0…1):
  - `level`: steady `1 − p`; earlyDrop `(1 − p)²`; lateDrop `1 − p²`.
  - `volume`: `round(start × (fadeTarget + (1 − fadeTarget) × level))`.
  - `bands`: for each weighted band `i`: `round(orig[i] + (depth × weight − orig[i]) × p^0.6)`; only weighted bands appear in the result.

- [ ] **Step 5: Run** `swift test` — Expected: PASS. Run `swift build` — Expected: builds `Segue`.

- [ ] **Step 6: Commit** `feat: package scaffold, recipe types and fade math`.

---

### Task 2: Recipe picker

**Files:**
- Create: `Sources/SegueCore/RecipePicker.swift`, `Tests/SegueCoreTests/RecipePickerTests.swift`

**Interfaces:**
- Consumes: `Recipe`, `TransitionSettings`, `EQFocus`, `FadeShape`.
- Produces:
  ```swift
  public struct RecipePicker: Sendable {
      public static let fadeTargets: [Double] = [0, 0.25, 0.45, 0.6]
      public private(set) var last: Recipe?
      public init()
      public mutating func next(settings: TransitionSettings, eqAvailable: Bool,
                                using rng: inout some RandomNumberGenerator) -> Recipe
  }
  ```

- [ ] **Step 1: Write the failing tests** (use a small seeded `SplitMix64` generator defined in the test file):

  ```swift
  @Test func valuesStayInRange() {       // 500 picks, default settings, eqAvailable true
      // each: 3...8 length, fadeTarget in RecipePicker.fadeTargets, depth in -1200...-600
  }
  @Test func neverRepeatsFocusOrTarget() {   // 500 picks: r[i].focus != r[i-1].focus && r[i].fadeTarget != r[i-1].fadeTarget
  }
  @Test func eqUnavailableGivesNoFocusButStillVariesTarget() {  // eqAvailable false: focus == .none always; fadeTarget differs from previous
  }
  @Test func eqEffectsOffGivesNoFocus() { // settings.eqEffects = false → focus == .none
  }
  @Test func variationOffIsFixed() {
      // settings.variation = false → every pick == Recipe(length: 5.5, fadeTarget: 0, shape: .steady, focus: .lows, depth: -1200)
      // and with eqAvailable false → same but focus .none
  }
  @Test func badRangeIsClampedAndSwapped() {
      // minLength 20, maxLength 0.2 → every length in 1...12, no crash
      // minLength == maxLength == 4 → length == 4
  }
  ```

- [ ] **Step 2: Run** `swift test --filter RecipePickerTests` — Expected: FAIL.

- [ ] **Step 3: Implement `RecipePicker.next`.** Clamp both lengths to 1…12 then order them; with variation off return the fixed recipe (length = midpoint of the clamped range); otherwise draw each field uniformly, excluding the previous focus and previous fade target from the candidates (focus exclusion is skipped when focus is forced to `.none`); store the result in `last`.

- [ ] **Step 4: Run** `swift test` — Expected: PASS.

- [ ] **Step 5: Commit** `feat: recipe picker with no-repeat rule`.

---

### Task 3: Control protocols, fakes and snapshot store

**Files:**
- Create: `Sources/SegueCore/Controlling.swift`, `Sources/SegueCore/SnapshotStore.swift`, `Tests/SegueCoreTests/Fakes.swift`, `Tests/SegueCoreTests/SnapshotStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PlayerState: Sendable { case playing, paused, stopped }
  public struct EQSnapshot: Codable, Equatable, Sendable {
      public var enabled: Bool; public var preset: String; public var bands: [Int] }   // 10 values
  public struct StateSnapshot: Codable, Equatable, Sendable {
      public var volume: Int; public var eq: EQSnapshot? }
  public protocol MusicControlling: Sendable {
      var isRunning: Bool { get }
      func playerState() -> PlayerState
      func trackKey() -> String?                 // stable identity of the current track, nil if none
      func trackTitle() -> (name: String, artist: String)?
      func volume() -> Int                       // 0...100
      func setVolume(_ v: Int)
      func nextTrack(); func play(); func pause()
  }
  public protocol EqualizerControlling: Sendable {
      func prepare() -> Bool                     // window open + minimized, controls cached; false if unavailable
      func snapshot() throws -> EQSnapshot
      func setEnabled(_ on: Bool) throws
      func setBands(_ values: [Int: Int]) throws
      func restore(_ s: EQSnapshot) throws
  }
  public protocol EngineClock: Sendable {
      func now() -> Double
      func sleep(_ seconds: Double) async
  }
  public struct SystemClock: EngineClock { public init() }
  public struct SnapshotStore: Sendable {
      public init(directory: URL)                // file: directory/snapshot.json
      public static var defaultDirectory: URL { get }   // ~/Library/Application Support/Segue
      public func save(_ s: StateSnapshot)
      public func load() -> StateSnapshot?       // nil if missing or unreadable
      public func clear()
  }
  ```
- Test fakes (in `Fakes.swift`, all `final class … @unchecked Sendable`):
  - `FakeClock`: `now()` starts at 0; `sleep(s)` adds `s` then runs any hooks whose time has passed; `at(_ t: Double, _ action: @escaping () -> Void)` registers a hook.
  - `FakeMusic`: mutable `state`, `key`, `vol`, `running = true`; `log: [String]` recording `"vol:N"`, `"next"`, `"play"`, `"pause"`; `nextTrack()` changes `key` to a new value unless `nextNeverStarts` is set, in which case it sets `state = .stopped`.
  - `FakeEQ`: `available = true`; current `EQSnapshot` (default enabled true, preset "Flat", bands all 0); `failAfterSetBandsCalls: Int?` makes `setBands` throw from that call on; `setBandsCalls`, `restoreCalls` counters; `setBands` on a non-"Manual" preset changes `preset` to "Manual" (mirrors Music).

- [ ] **Step 1: Write the failing tests** in `SnapshotStoreTests.swift`, each using a fresh temp directory:

  ```swift
  @Test func roundTrip()            // save then load == original (with and without eq)
  @Test func loadMissingIsNil()
  @Test func clearRemoves()         // save, clear, load == nil
  @Test func corruptFileIsNil()     // write "not json" to snapshot.json → load() == nil, no crash
  @Test func saveCreatesDirectory() // directory does not exist beforehand
  ```

- [ ] **Step 2: Run** `swift test --filter SnapshotStoreTests` — Expected: FAIL.
- [ ] **Step 3: Implement `Controlling.swift`, `SnapshotStore.swift` and `Fakes.swift`.** `SystemClock.now()` uses `ProcessInfo.processInfo.systemUptime`; `sleep` uses `Task.sleep`.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat: control protocols, fakes and snapshot store`.

---

### Task 4: Transition engine — DJ skip sequence

**Files:**
- Create: `Sources/SegueCore/TransitionEngine.swift`, `Tests/SegueCoreTests/EngineSkipTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces:
  ```swift
  public actor TransitionEngine {
      public static let tick = 1.0 / 30.0
      public static let nextTrackTimeout = 5.0
      public init(music: MusicControlling, eq: EqualizerControlling, store: SnapshotStore,
                  clock: EngineClock, rng: any RandomNumberGenerator = SystemRandomNumberGenerator())
      public func djSkip(settings: TransitionSettings) async
      public private(set) var lastRecipe: Recipe?
      public private(set) var isRunning: Bool
      public func setRunningHandler(_ handler: (@Sendable (Bool) -> Void)?)
  }
  ```

- [ ] **Step 1: Write the failing tests** (helper `makeEngine()` returns engine + fakes + temp store; settings with `variation = false` unless noted, so the recipe is the fixed 5.5 s lows cut):

  ```swift
  @Test func normalSkipOrderAndRestore() async {
      // music playing, vol 80, eq preset "Rock" enabled, bands all 50
      // after djSkip: log contains exactly one "next"; every "vol:" before "next" is non-increasing and the last is "vol:0";
      // vols after "next" are non-decreasing and end at "vol:80";
      // eq.current == original snapshot (preset "Rock", bands 50, enabled true); eq.setBandsCalls > 0;
      // clock.now() ≈ 5.5 + 1.5 (± 0.2); store.load() == nil; engine.isRunning == false
  }
  @Test func snapshotIsOnDiskDuringTransition() async {
      // clock.at(2.0) { captured = store.load() } → captured == StateSnapshot(volume: 80, eq: original)
  }
  @Test func eqOffIsTurnedOnThenOffAgain() async {
      // eq.current.enabled = false → at clock 2.0 eq.current.enabled == true; after skip == false
  }
  @Test func notPlayingIsPlainSkip() async {
      // state .paused → log == ["next"]; no setBands; clock.now() == 0
  }
  @Test func musicNotRunningDoesNothing() async {   // running = false → log empty
  }
  @Test func eqUnavailableIsFadeOnly() async {      // eq.available = false → setBandsCalls == 0, restoreCalls == 0, one "next", ends at vol 80
  }
  @Test func eqEffectsOffIsFadeOnly() async          // settings.eqEffects = false → same expectations
  @Test func nextTrackNeverStartsStillRestores() async {
      // music.nextNeverStarts = true → after ≈ 5.5 + 5.0 s, volume back to 80, eq restored, store empty
  }
  @Test func zeroStartingVolume() async {            // vol 0 → one "next", final volume 0, no crash
  }
  @Test func runningHandlerFiresTrueThenFalse() async
  @Test func variationProducesDifferentRecipes() async {
      // variation = true, seeded rng: two skips with clock advanced 60 s between → lastRecipe differs in focus and fadeTarget
  }
  ```

- [ ] **Step 2: Run** `swift test --filter EngineSkipTests` — Expected: FAIL.

- [ ] **Step 3: Implement `djSkip`** following the spec's sequence:
  1. Return if `!music.isRunning`. If `playerState() != .playing`: `nextTrack()` and return.
  2. `eqOK = settings.eqEffects && eq.prepare()`; take `StateSnapshot(volume:, eq: eqOK ? try? eq.snapshot() : nil)` (a failed snapshot means `eqOK = false`); `store.save`.
  3. Pick the recipe (`eqAvailable: eqOK`), set `lastRecipe`, `isRunning = true`.
  4. If the recipe has a focus and the EQ is off, `setEnabled(true)`.
  5. Loop until `clock.now() − start ≥ recipe.length`: set volume and bands from `FadeCurve` at `progress = elapsed / length`, then `await clock.sleep(tick)`.
  6. `setVolume(0)`, `nextTrack()`, then poll every tick until `playerState() == .playing && trackKey() != startKey`, or `nextTrackTimeout` passes.
  7. `eq.restore(snapshot.eq)` if there is one.
  8. Fade volume 0 → saved over `settings.fadeIn` with `sin(progress × π/2)`; finish with `setVolume(saved)`.
  9. `store.clear()`, `isRunning = false`.
  Put restore-and-clear in one private `finish(restoreVolume: Bool)` so Task 5 reuses it.

- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat: transition engine DJ skip sequence`.

---

### Task 5: Transition engine — rules and recovery

**Files:**
- Modify: `Sources/SegueCore/TransitionEngine.swift`
- Create: `Tests/SegueCoreTests/EngineRulesTests.swift`

**Interfaces:**
- Produces (added to `TransitionEngine`):
  ```swift
  public static let searchWindow = 3.0      // a skip this soon after a transition starts search mode
  public static let searchRelease = 10.0    // seconds without a skip before DJ skips resume
  public func recoverIfNeeded()             // restore from a snapshot left on disk, then clear it
  ```

- [ ] **Step 1: Write the failing tests:**

  ```swift
  @Test func secondPressDuringFadeOutSkipsInstantly() async {
      // clock.at(2.0) { Task { await engine.djSkip(settings) } }
      // → exactly one "next", issued at clock ≈ 2.0; eq restored; volume 80 right after; total time < 3 s
  }
  @Test func pressDuringFadeInFinishesAtFullVolume() async {
      // second press at 5.5 + 0.5 (mid fade-in) → a second "next" (search mode skip), final volume 80, eq restored, store empty
  }
  @Test func skipWithinThreeSecondsOfATransitionIsInstant() async {
      // full skip; advance clock 2 s; djSkip → log gains only "next"; no new "vol:" entries
  }
  @Test func searchModeLastsUntilTenSecondsWithoutASkip() async {
      // after entering search mode: skips at +4 s, +4 s, +4 s are all instant;
      // then advance 10.1 s → next djSkip is a full transition (setBandsCalls increases)
  }
  @Test func skipAfterThreeSecondsIsNormal() async   // full skip; advance 3.1 s; djSkip → full transition
  @Test func trackChangeMidTransitionAbortsWithoutSkip() async {
      // clock.at(2.0) { music.key = "other" } → no "next" in log; volume 80; eq restored; store empty
  }
  @Test func userVolumeChangeIsRespected() async {
      // clock.at(2.0) { music.vol = 55 } → after skip: volume still 55, no "vol:" entries after t=2.0,
      // one "next", eq restored (sweep continued: setBandsCalls keeps growing after 2.0)
  }
  @Test func eqFailureMidSweepFallsBackToFade() async {
      // eq.failAfterSetBandsCalls = 10 → one "next", volume ends 80, no crash, restore attempted once
  }
  @Test func musicQuitsMidTransition() async {
      // clock.at(2.0) { music.running = false } → engine returns promptly, isRunning == false, snapshot still on disk
  }
  @Test func recoverRestoresAndClears() async {
      // store.save(StateSnapshot(volume: 70, eq: snap)) → recoverIfNeeded(): music.vol == 70, eq.current == snap, store.load() == nil
  }
  @Test func recoverWithNothingOnDiskDoesNothing() async
  ```

- [ ] **Step 2: Run** `swift test --filter EngineRulesTests` — Expected: FAIL.

- [ ] **Step 3: Implement the rules.**
  - Interrupt: if `djSkip` is called while `isRunning`, set a private `interrupt = .skip` flag and return. Every loop in the running transition (fade-out, wait-for-next, fade-in) checks the flag each tick. On `.skip`: if `nextTrack()` has not been sent yet, send it; restore EQ; set volume to the saved level (unless the user changed it); clear the store; set `searchMode = true`; record `lastSkipAt`.
  - Search mode: at the top of `djSkip` when not running — if `searchMode && now − lastSkipAt < searchRelease`: plain `nextTrack()`, update `lastSkipAt`, return. Else if `now − lastTransitionEnd < searchWindow`: set `searchMode = true`, plain skip, return. Otherwise `searchMode = false` and run normally.
  - Track change: each fade-out tick, if `trackKey() != startKey` → `finish(restoreVolume: true)` without skipping.
  - User volume: before each volume write, if `abs(music.volume() − lastWritten) > 1` → stop writing volume for the rest of this transition (including fade-in) and skip the volume restore.
  - EQ failure: any throw from `setBands`/`setEnabled` sets `eqOK = false` for this transition; still attempt `restore` once at the end, ignoring its error.
  - Music quits: if `!music.isRunning` during any loop → `isRunning = false`, return, leaving the snapshot on disk.
  - `recoverIfNeeded`: load; if present and Music is running, set volume, `eq.prepare()` then `restore`; clear.

- [ ] **Step 4: Run** `swift test` — Expected: PASS (Task 4 tests included).
- [ ] **Step 5: Commit** `feat: search mode, interruption rules and crash recovery`.

---

### Task 6: Transition engine — faded pause and resume

**Files:**
- Modify: `Sources/SegueCore/TransitionEngine.swift`
- Create: `Tests/SegueCoreTests/EnginePauseTests.swift`

**Interfaces:**
- Produces: `public func togglePause(settings: TransitionSettings) async`

- [ ] **Step 1: Write the failing tests:**

  ```swift
  @Test func pauseFadesThenPausesThenRestoresVolume() async {
      // playing, vol 80 → vols non-increasing to 0, then "pause", then "vol:80"; clock ≈ 0.6; state .paused
  }
  @Test func resumeStartsSilentAndFadesUp() async {
      // paused, vol 80 → "vol:0", "play", vols non-decreasing ending "vol:80"; clock ≈ 0.6
  }
  @Test func settingOffIsPlainToggle() async {
      // fadeOnPause = false: playing → log == ["pause"]; paused → log == ["play"]; clock == 0
  }
  @Test func stoppedStateJustPlays() async           // .stopped → log == ["play"]
  @Test func pauseDuringDJSkipCancelsAndPauses() async {
      // djSkip running; clock.at(2.0) { Task { await engine.togglePause(settings) } }
      // → no "next"; eq restored; volume 80; "pause" in log; store empty
  }
  @Test func userVolumeChangeDuringPauseFadeIsKept() async {
      // clock.at(0.3) { music.vol = 40 } → "pause" still sent; final volume 40
  }
  @Test func musicNotRunningDoesNothing() async
  ```

- [ ] **Step 2: Run** `swift test --filter EnginePauseTests` — Expected: FAIL.
- [ ] **Step 3: Implement `togglePause`.** While a DJ skip is running, set `interrupt = .cancelAndPause`: the running transition restores EQ and volume without skipping, clears the store, then calls `music.pause()`. Otherwise fade with `TransitionSettings.pauseFade` using the steady shape, applying the same user-volume rule as Task 5. No snapshot file is written for pause fades.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat: faded pause and resume`.

---

### Task 7: Music controller (ScriptingBridge)

**Files:**
- Create: `Sources/Segue/MusicAppController.swift`
- Modify: `Sources/Segue/SegueApp.swift` (add `--probe` mode)

**Interfaces:**
- Consumes: `MusicControlling`, `PlayerState`.
- Produces: `final class MusicAppController: MusicControlling, @unchecked Sendable { init() }`

- [ ] **Step 1: Implement `MusicAppController`.**
  - `SBApplication(bundleIdentifier: "com.apple.Music")`, reached through hand-written `@objc protocol`s with optional members (`playerState`, `soundVolume`, `setSoundVolume:`, `currentTrack`, `nextTrack`, `playpause`, `pause`; track: `name`, `artist`, `persistentID`, `duration`).
  - `isRunning`: `NSRunningApplication.runningApplications(withBundleIdentifier:)` is non-empty. Never launch Music: check `isRunning` before every call.
  - Player state four-char codes: playing `0x6B505350` ('kPSP'), paused `0x6B505370` ('kPSp'), anything else → `.stopped`.
  - `trackKey`: `"\(persistentID)|\(name)|\(artist)|\(Int(duration))"`, nil when there is no current track.
  - `play()` sends `playpause` only when state is not playing.
- [ ] **Step 2: Add `--probe`** to `SegueApp.swift`: when launched with that argument, print `running`, `state`, `trackKey`, `volume`, then set volume to `volume − 10`, wait 0.5 s, set it back, print the read-back values and exit without starting the UI.
- [ ] **Step 3: Verify** with a song playing in Music: `swift run Segue --probe`. Expected: `state: playing`, a non-nil track key, and the two read-backs equal `volume − 10` then `volume`. With Music quit: `running: false` and Music does not launch.
- [ ] **Step 4: Commit** `feat: Apple Music controller`.

---

### Task 8: Equalizer controller (Accessibility)

**Files:**
- Create: `Sources/Segue/AXEqualizerController.swift`
- Modify: `Sources/Segue/SegueApp.swift` (extend `--probe`)

**Interfaces:**
- Consumes: `EqualizerControlling`, `EQSnapshot`.
- Produces:
  ```swift
  final class AXEqualizerController: EqualizerControlling, @unchecked Sendable {
      init()
      static var hasAccessibilityPermission: Bool { get }      // AXIsProcessTrusted()
      static func requestAccessibilityPermission()             // AXIsProcessTrustedWithOptions prompt
  }
  enum EQError: Error { case noPermission, windowUnavailable, controlMissing(String) }
  ```

- [ ] **Step 1: Implement.**
  - `prepare()`: return false without permission or if Music isn't running. Find the window titled "Equalizer" on Music's AX application element; if absent, press the "Equalizer" item of the "Window" menu in the menu bar and poll up to 1 s. Set `AXMinimized` to true if it isn't. Cache: the 10 band sliders, found by `AXDescription` — `"32 hertz", "64 hertz", "125 hertz", "250 hertz", "500 hertz", "1 kilohertz", "2 kilohertz", "4 kilohertz", "8 kilohertz", "16 kilohertz"` (the "Preamp" slider is never touched); the window's one checkbox (on/off); its one pop-up button (preset). If the cache is already valid (a cheap read of one slider succeeds) return true without searching again.
  - `snapshot()`: checkbox value, pop-up button's `AXValue` (preset name), 10 slider values as `Int`.
  - `setBands`: set `AXValue` on the cached sliders. Any AX error invalidates the cache and throws.
  - `setEnabled`: press the checkbox only if its value differs.
  - `restore`: if `preset != "Manual"`, press the pop-up, press the menu item with that title, and stop there (the preset sets the sliders); if "Manual", write the 10 band values. Then `setEnabled(snapshot.enabled)`.
  - Guard all access with a lock; set `AXUIElementSetMessagingTimeout` to 0.5 s on the app element.
- [ ] **Step 2: Extend `--probe`:** print permission, `prepare()` result and the snapshot; cut bands 0–4 to −1200 for 3 s; `restore`; print the snapshot again and whether it equals the first.
- [ ] **Step 3: Verify** with a song playing: `swift run Segue --probe`. Expected: `prepare: true`, bass audibly drops for 3 s, second snapshot equals the first, the Equalizer window stays minimized and Music does not come to the front. Repeat once with a named preset (e.g. "Rock") selected beforehand and once with the EQ switched off: both come back as they were.
- [ ] **Step 4: Commit** `feat: Equalizer controller via Accessibility`.

---

### Task 9: App — hotkeys, settings, menu bar panel, packaging

**Files:**
- Create: `Sources/Segue/HotkeyManager.swift`, `Sources/Segue/SettingsStore.swift`, `Sources/Segue/PanelView.swift`, `scripts/build-app.sh`, `scripts/make-signing-cert.sh`
- Modify: `Sources/Segue/SegueApp.swift`

**Interfaces:**
- Consumes: `TransitionEngine`, `TransitionSettings`, `MusicAppController`, `AXEqualizerController`, `SnapshotStore`, `SystemClock`.
- Produces:
  ```swift
  struct Shortcut: Codable, Equatable { var keyCode: UInt32; var modifiers: UInt32   // Carbon modifier flags
      static let djSkip = Shortcut(keyCode: 1, modifiers: UInt32(optionKey | cmdKey))        // ⌥⌘S
      static let pause  = Shortcut(keyCode: 35, modifiers: UInt32(optionKey | cmdKey))       // ⌥⌘P
      var display: String { get } }                                                          // e.g. "⌥⌘S"
  final class HotkeyManager { func register(_ s: Shortcut, id: UInt32, action: @escaping () -> Void) -> Bool
                              func unregisterAll() }
  @MainActor final class SettingsStore: ObservableObject {      // UserDefaults-backed, @Published
      var transition: TransitionSettings; var skipShortcut: Shortcut; var pauseShortcut: Shortcut; var startAtLogin: Bool }
  @MainActor final class AppModel: ObservableObject {           // in SegueApp.swift
      @Published var title: String; @Published var isTransitioning: Bool; @Published var hasAccessibility: Bool
      func djSkip(); func togglePause() }
  ```

- [ ] **Step 1: `HotkeyManager`** — Carbon `RegisterEventHotKey` + one `InstallEventHandler` for `kEventHotKeyPressed`; `register` returns false when the combination is refused.
- [ ] **Step 2: `SettingsStore`** — persists each field under `segue.*` keys; `startAtLogin` calls `SMAppService.mainApp.register()` / `unregister()` and reverts the toggle if that throws.
- [ ] **Step 3: `AppModel` + `SegueApp`** — on launch: build controllers, `SnapshotStore(directory: .defaultDirectory)`, engine; call `recoverIfNeeded()`; register both hot keys (re-register when a shortcut changes); a 1 s timer refreshes `title` ("Name — Artist" or "Not playing") and `hasAccessibility`; the engine's running handler drives `isTransitioning` on the main actor. Scene: `MenuBarExtra { PanelView() } label: { Image(systemName: "waveform") }` with `.menuBarExtraStyle(.window)` and `.symbolEffect(.pulse, isActive: model.isTransitioning)`. `NSApp.setActivationPolicy(.accessory)`.
- [ ] **Step 4: `PanelView`** — in spec order: title; DJ Skip and Play/Pause buttons; length range (two sliders 1–12 s, kept min ≤ max); Variation, EQ effects toggles; fade-in slider (0–5 s); Fade on pause toggle; two shortcut rows (button showing `display`; clicking it records the next key-down that has at least one of ⌃⌥⌘, via a local `NSEvent` monitor; if `register` fails show "Shortcut unavailable" and keep the old one); Start at login toggle; "Grant Accessibility access" button when `!hasAccessibility`; an explanatory line when Music can't be controlled (Automation denied); Quit.
- [ ] **Step 5: `scripts/build-app.sh`** — `swift build -c release`; assemble `build/Segue.app/Contents/{MacOS/Segue,Info.plist}`; Info.plist keys: `CFBundleIdentifier` `io.github.segue.Segue`, `CFBundleName` `Segue`, `CFBundleExecutable` `Segue`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `0.1.0`, `LSMinimumSystemVersion` `14.0`, `LSUIElement` true, `NSAppleEventsUsageDescription` "Segue controls Music to fade and skip songs."; sign with the identity "Segue Local Signing" if `security find-identity -p codesigning` lists it, else ad-hoc (`codesign --force --sign -`) and print a note that permissions will need re-granting after each rebuild.
- [ ] **Step 6: `scripts/make-signing-cert.sh`** — creates a self-signed code-signing certificate named "Segue Local Signing" with `openssl` and imports it into the login keychain with `security import … -T /usr/bin/codesign`. It prints that macOS may ask for the login password; it is run by the user, once.
- [ ] **Step 7: Verify:** `swift test` passes; `./scripts/build-app.sh` produces `build/Segue.app`; `open build/Segue.app` shows the menu bar icon; grant Automation and Accessibility when prompted; ⌥⌘S during a playing song fades, sweeps, skips and fades in; ⌥⌘P fades to pause and back; the icon pulses during a transition.
- [ ] **Step 8: Commit** `feat: menu bar app, hotkeys, settings and packaging`.

---

### Task 10: README, license and manual checklist

**Files:**
- Create: `README.md`, `LICENSE` (MIT, holder "Uzair", 2026), `docs/manual-checklist.md`

- [ ] **Step 1: `docs/manual-checklist.md`** — the spec's nine manual checks as checkboxes, each with its expected result.
- [ ] **Step 2: `README.md`** — sections in the spec's order: what it is and how it works; requirements (macOS 14+, Apple Music subscription or library, Swift toolchain); build and run (`./scripts/build-app.sh`, optional signing-cert script, the test command that worked in Task 1); permissions (Automation, Accessibility); shortcuts and settings; known limitations (the five in the spec, verbatim in meaning); roadmap (the seven items in the spec); license.
- [ ] **Step 3: Run the manual checklist** against Apple Music with a streamed song and tick each item in the file; fix anything that fails before committing.
- [ ] **Step 4: Commit** `docs: README, license and manual checklist`.

Publishing to GitHub is not part of this plan: it needs the owner's choice of public or private and either the `gh` tool or an empty repository URL.
