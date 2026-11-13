import AppKit
import ApplicationServices
import SegueCore

enum EQError: Error {
    case noPermission, windowUnavailable, controlMissing(String)
}

/// Drives Music's Equalizer window through the Accessibility API.
/// Music's scripted EQ properties don't change the live sound; these controls do.
final class AXEqualizerController: EqualizerControlling, @unchecked Sendable {
    /// Accessibility labels of the ten band sliders, lowest band first.
    static let bandLabels = ["32 hertz", "64 hertz", "125 hertz", "250 hertz", "500 hertz",
                             "1 kilohertz", "2 kilohertz", "4 kilohertz", "8 kilohertz", "16 kilohertz"]
    private static let windowTitle = "Equalizer"

    private let lock = NSRecursiveLock()
    private var sliders: [AXUIElement] = []
    private var checkbox: AXUIElement?
    private var presetButton: AXUIElement?

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - EqualizerControlling

    func prepare() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Self.hasAccessibilityPermission else { return false }
        if cacheIsValid { return true }
        invalidate()
        guard let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: MusicAppController.bundleID).first?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)

        var window = equalizerWindow(of: app)
        if window == nil {
            // Opening it from Music's menu does not bring Music to the front.
            guard let item = menuItem(of: app, menu: "Window", item: Self.windowTitle) else { return false }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            for _ in 0..<20 where window == nil {
                Thread.sleep(forTimeInterval: 0.05)
                window = equalizerWindow(of: app)
            }
            // Only tuck away a window Segue opened; one the user has open stays where it is.
            if let window {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
        guard let window else { return false }

        let controls = descendants(of: window, depth: 3)
        let found = Self.bandLabels.compactMap { label in
            controls.first { role($0) == kAXSliderRole as String && string($0, kAXDescriptionAttribute) == label }
        }
        guard found.count == Self.bandLabels.count,
              let box = controls.first(where: { role($0) == kAXCheckBoxRole as String }),
              let popup = controls.first(where: { role($0) == kAXPopUpButtonRole as String }) else { return false }
        sliders = found
        checkbox = box
        presetButton = popup
        return true
    }

    func snapshot() throws -> EQSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let checkbox, let presetButton, sliders.count == Self.bandLabels.count else {
            throw EQError.windowUnavailable
        }
        return EQSnapshot(enabled: try number(checkbox) != 0,
                          preset: string(presetButton, kAXValueAttribute) ?? "Manual",
                          bands: try sliders.map { Int(try number($0).rounded()) })
    }

    func setEnabled(_ on: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let checkbox else { throw EQError.windowUnavailable }
        if (try number(checkbox) != 0) != on {
            try check(AXUIElementPerformAction(checkbox, kAXPressAction as CFString), "on/off checkbox")
        }
    }

    func setBands(_ values: [Int: Int]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sliders.count == Self.bandLabels.count else { throw EQError.windowUnavailable }
        for (band, value) in values where sliders.indices.contains(band) {
            let clamped = min(max(value, -1200), 1200)
            try check(AXUIElementSetAttributeValue(sliders[band], kAXValueAttribute as CFString,
                                                   NSNumber(value: clamped)), Self.bandLabels[band])
        }
    }

    func restore(_ s: EQSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        if s.preset == "Manual" || !selectPreset(s.preset) {
            try setBands(Dictionary(uniqueKeysWithValues: s.bands.enumerated().map { ($0.offset, $0.element) }))
        }
        try setEnabled(s.enabled)
    }

    // MARK: - Accessibility plumbing

    private var cacheIsValid: Bool {
        guard let first = sliders.first, checkbox != nil, presetButton != nil else { return false }
        return (try? number(first)) != nil
    }

    private func invalidate() {
        sliders = []
        checkbox = nil
        presetButton = nil
    }

    /// Picks a named preset from the pop-up. False if the menu or the item can't be reached.
    private func selectPreset(_ name: String) -> Bool {
        guard let presetButton else { return false }
        if string(presetButton, kAXValueAttribute) == name { return true }
        guard AXUIElementPerformAction(presetButton, kAXPressAction as CFString) == .success else { return false }
        var item: AXUIElement?
        for _ in 0..<10 where item == nil {
            item = descendants(of: presetButton, depth: 2).first {
                role($0) == kAXMenuItemRole as String && string($0, kAXTitleAttribute) == name
            }
            if item == nil { Thread.sleep(forTimeInterval: 0.03) }
        }
        guard let item else {
            // Don't leave the menu hanging open.
            if let menu = children(of: presetButton).first {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
            return false
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private func equalizerWindow(of app: AXUIElement) -> AXUIElement? {
        elements(app, kAXWindowsAttribute).first { string($0, kAXTitleAttribute) == Self.windowTitle }
    }

    private func menuItem(of app: AXUIElement, menu: String, item: String) -> AXUIElement? {
        guard let bar = element(app, kAXMenuBarAttribute),
              let barItem = children(of: bar).first(where: { string($0, kAXTitleAttribute) == menu }),
              let menuElement = children(of: barItem).first else { return nil }
        return children(of: menuElement).first { string($0, kAXTitleAttribute) == item }
    }

    private func descendants(of root: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        let kids = children(of: root)
        return kids + kids.flatMap { descendants(of: $0, depth: depth - 1) }
    }

    private func children(of e: AXUIElement) -> [AXUIElement] { elements(e, kAXChildrenAttribute) }

    private func value(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &out) == .success ? out : nil
    }

    private func elements(_ e: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(e, attribute) as? [AXUIElement] ?? []
    }

    private func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(e, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func string(_ e: AXUIElement, _ attribute: String) -> String? { value(e, attribute) as? String }
    private func role(_ e: AXUIElement) -> String? { string(e, kAXRoleAttribute) }

    private func number(_ e: AXUIElement) throws -> Double {
        guard let n = value(e, kAXValueAttribute) as? NSNumber else {
            invalidate()
            throw EQError.windowUnavailable
        }
        return n.doubleValue
    }

    private func check(_ result: AXError, _ control: String) throws {
        guard result == .success else {
            invalidate()
            throw EQError.controlMissing(control)
        }
    }
}
