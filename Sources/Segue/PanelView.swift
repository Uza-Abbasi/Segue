import SegueCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(action: model.djSkip) {
                    Label("DJ Skip", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button(action: model.togglePause) {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            if !model.canControlMusic {
                notice("Segue isn't allowed to control Music. Turn it on in System Settings → Privacy & Security → Automation.")
            }
            if !model.hasAccessibility {
                notice("Without Accessibility access, skips fade but don't use the equalizer.")
                Button("Grant Accessibility access", action: model.grantAccessibility)
            }

            Divider()

            lengthRow("Shortest transition", value: $settings.transition.minLength)
            lengthRow("Longest transition", value: $settings.transition.maxLength)
            Toggle("Vary each transition", isOn: $settings.transition.variation)
            Toggle("Equalizer effects", isOn: $settings.transition.eqEffects)
            sliderRow("Next song fades in", value: $settings.transition.fadeIn, range: 0...5)
            Toggle("Fade on pause and resume", isOn: $settings.transition.fadeOnPause)

            Divider()

            shortcutRow("DJ skip", role: .skip, shortcut: settings.skipShortcut)
            shortcutRow("Pause / resume", role: .pause, shortcut: settings.pauseShortcut)
            if let error = model.shortcutError { notice(error) }
            Toggle("Start at login", isOn: $settings.startAtLogin)

            Divider()

            Button("Quit Segue") { NSApplication.shared.terminate(nil) }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 320)
        .onChange(of: settings.transition.minLength) { _, new in
            if new > settings.transition.maxLength { settings.transition.maxLength = new }
        }
        .onChange(of: settings.transition.maxLength) { _, new in
            if new < settings.transition.minLength { settings.transition.minLength = new }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lengthRow(_ label: String, value: Binding<Double>) -> some View {
        sliderRow(label, value: value, range: RecipePicker.lengthLimits)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f s", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.5)
        }
    }

    private func shortcutRow(_ label: String, role: AppModel.ShortcutRole, shortcut: Shortcut) -> some View {
        HStack {
            Text(label)
            Spacer()
            Button(model.recording == role ? "Press keys…" : shortcut.display) { model.record(role) }
                .monospaced()
        }
    }
}
