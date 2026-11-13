# Segue beta: design spec

Date: 2026-11-12
Status: awaiting review

## Purpose

Segue is a macOS menu bar app, for one person's own use, that makes skipping a song in Apple Music sound like a DJ transition. Instead of cutting the song off, a "DJ skip" fades the volume and sweeps the equalizer, then skips, and fades the next song in. Each skip sounds different from the last.

The beta is a proof of concept to publish on GitHub. Success means: pressing the shortcut during any streamed Apple Music song produces a smooth, varied transition, and afterwards the volume and equalizer are exactly as the user left them.

## Scope

In the beta:

- DJ skip (fade + EQ sweep + skip + fade-in), with randomized variation
- Faded pause and resume
- Menu bar panel with controls and settings
- Two global keyboard shortcuts
- Start at login (optional)
- README with build steps, permissions, roadmap and known limitations

Not in the beta:

- Spotify or any other service
- Loops, overlapping crossfades, audio capture (ruled out)
- Tempo, lyric or section data
- Taking over the keyboard's media keys
- Transition log, replay button, demo video (round 2)
- Windows, iOS, App Store distribution

## Constraints

- macOS 15, Apple Music's Music app, streamed songs as the main case.
- Segue never touches audio. It only remote-controls Music:
  - Volume, skip, play/pause, track info: Music's scripting interface (Apple Events).
  - Equalizer: the sliders, on/off checkbox and preset menu of Music's Equalizer window, through the macOS Accessibility API. Music's scripted EQ properties do not affect live sound and are not used.
- Built with the Swift command-line tools (Swift 6.1, no Xcode).
- Permissions needed: Automation (control Music) and Accessibility.

## User interface

### Shortcuts

| Shortcut | Action |
|---|---|
| ⌥⌘S | DJ skip |
| ⌥⌘P | Faded pause / resume |

Both are global and can be changed in settings.

### Menu bar

- An icon in the menu bar. It pulses while a transition is running.
- Clicking it opens a panel with:
  - Current song title and artist
  - DJ Skip button, Play/Pause button
  - Settings:
    - Transition length range (default 3–8 s, limits 1–12 s)
    - Variation on/off (off = always fade to 0, steady shape, lows cut, midpoint length)
    - EQ effects on/off
    - Fade-in length for the next song (default 1.5 s)
    - Fade on pause/resume on/off (default on, 0.6 s)
    - The two shortcuts
    - Start at login (default off)
  - A "Grant Accessibility access" button, shown only when that permission is missing
  - Quit

## Transitions

### Recipe

Each DJ skip uses one recipe:

| Field | Values |
|---|---|
| Length | Random within the user's range |
| Fade target | 0%, 25%, 45% or 60% of the starting volume |
| Fade shape | Early drop, steady, or late drop |
| EQ focus | None, lows, mids, highs, or lows + highs |
| EQ depth | −6 to −12 dB at the centre of the focus |

EQ focus bands (Music's 10-band equalizer):

- Lows: 32, 64, 125, 250 Hz (500 Hz at half depth)
- Mids: 500 Hz, 1 kHz, 2 kHz (250 Hz and 4 kHz at half depth)
- Highs: 4, 8, 16 kHz (2 kHz at half depth)

No-repeat rule: a new recipe must differ from the previous one in EQ focus and in fade target.

If EQ effects are off or the equalizer is unavailable, EQ focus is always "none".

### DJ skip sequence

1. Read Music's state. If Music is not playing, send a plain skip and stop.
2. Save a snapshot: volume, EQ on/off, EQ preset name, all slider values. Write it to disk.
3. If the recipe uses EQ and the EQ is off, turn it on.
4. Over the recipe's length, about 30 times a second, timed against the clock: set the volume along the fade shape toward the fade target, and move the focus sliders toward their depth.
5. Set volume to 0 and send next track. Wait until the new track is playing (up to 5 s).
6. Over the fade-in length, fade the volume from 0 to the saved level and move the focus sliders from their swept values back to the saved ones, so the next song comes in through the same filter (changed 2026-11-13; the sliders used to snap back before the fade-in).
7. Restore the preset and the EQ on/off state.
8. Delete the snapshot from disk.

### Faded pause / resume

- Pause: fade the volume to 0 over 0.6 s, pause, restore the volume.
- Resume: set volume to 0, play, fade up to the saved level over 0.6 s.
- With the setting off, the shortcut is a plain play/pause.

### Rules during a transition

- **Search mode.** A DJ skip pressed during a transition, or within 3 s of one finishing, skips instantly and restores state. Further skips stay instant until one song has played for 10 s.
- **Song changes on its own.** If the track changes before step 5, stop, restore the snapshot and do not skip.
- **User changes the volume.** If the volume read back differs from the last value Segue set, keep the user's level, stop managing volume for this transition, and do not restore the saved volume. The EQ part continues and is restored as normal.
- **Music quits or stops responding.** Abandon the transition; restore on next contact.

## Equalizer handling

- At launch, and again if the window is lost, Segue opens Window > Equalizer through Music's menu and minimizes the window to the Dock. Both were tested: this does not bring Music to the front, and slider changes are audible while minimized.
- Sliders are found by their accessibility label ("32 hertz", "1 kilohertz", …) once, and the references are kept. They are looked up again only if a call fails.
- Slider values are hundredths of a dB, from −1200 to 1200.
- Restoring a preset: re-select the saved preset from the window's pop-up menu. If it was "Manual", write the saved slider values back.

## Architecture

A Swift package with one library target and one app target.

| Unit | Responsibility | Depends on |
|---|---|---|
| `MusicControlling` (protocol) + `MusicAppController` | Player state, track identity, position, volume get/set, next track, play, pause | Apple Events to Music |
| `EqualizerControlling` (protocol) + `AXEqualizerController` | Ensure window, snapshot, set band values, set on/off, restore | Accessibility API |
| `Recipe`, `RecipePicker` | Recipe model; random pick with the no-repeat rule; injectable random source | Nothing |
| `FadeCurve` | Maps progress 0–1 to a level for each fade shape | Nothing |
| `TransitionEngine` | Runs the DJ skip and pause/resume sequences; applies the rules above; injectable clock | The two protocols, `RecipePicker`, `FadeCurve`, `SnapshotStore` |
| `SnapshotStore` | Saves and loads the volume/EQ snapshot on disk for crash recovery | File system |
| `Settings` | User settings in UserDefaults | Nothing |
| `HotkeyManager` | Registers the two global shortcuts | Carbon hot key API |
| App (`SegueApp`, panel view) | Menu bar icon, panel, wiring, start at login | SwiftUI `MenuBarExtra`, `SMAppService` |

The engine only talks to the two protocols, so tests run it against fakes with a fake clock.

Packaging: a script builds the release binary, assembles `Segue.app` with an `Info.plist` (menu-bar-only app, Apple Events usage text), and signs it with a self-signed certificate created once on this Mac, so macOS keeps the permissions across rebuilds.

## Error handling

| Situation | Behaviour |
|---|---|
| Accessibility permission missing | Fade-only transitions; panel shows the grant button |
| Automation permission missing | Panel explains how to allow control of Music; shortcuts do nothing |
| Equalizer window can't be opened or a slider is missing | Fade-only for that transition; retry setup on the next one |
| Snapshot found on disk at launch | Restore volume and EQ from it, then delete it |
| Music not running | DJ skip and pause do nothing |
| Next track doesn't start within 5 s | Restore volume and EQ anyway |

## Testing

Automated (Swift Testing, no Music needed):

- `RecipePicker`: values stay in range; no-repeat rule holds over many picks; variation off gives the fixed recipe; EQ off gives focus "none".
- `FadeCurve`: endpoints and monotonic decrease for each shape.
- `TransitionEngine` with fakes and a fake clock: normal skip ordering; not-playing gives a plain skip; search mode; track change mid-transition aborts and restores; user volume change is respected; snapshot is written before and removed after; restore happens when the next track never starts.
- `SnapshotStore`: round trip.

Manual checklist against Apple Music, streamed song:

- DJ skip five times in a row: each sounds different, EQ and volume return to the starting values.
- Start with a named preset selected, and with the EQ off: both are restored.
- Skip twice quickly: second is instant.
- Change the volume mid-fade: it stays where it was put.
- Skip in the last few seconds of a song: no double skip.
- Faded pause and resume.
- Revoke Accessibility: fade-only and the grant button appears.
- Force-quit Segue mid-transition and relaunch: EQ and volume are restored.
- Equalizer stays minimized and Music never comes to the front.

## README contents

- What it is and how it works (remote control, no audio access)
- Requirements, build and run steps, the two permissions
- Shortcuts and settings
- Known limitations: Apple Music on macOS only; AirPlay output may make fades sound stepped; Music's own Crossfade setting is left alone; the EQ route may break if Apple changes the Equalizer window; EQ cuts are limited to −12 dB
- Roadmap: demo video; transition log and replay; Spotify; tempo-matched timing; jump to outro; loops; better shuffle and an AI-music filter
- License: MIT
