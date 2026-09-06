import Carbon
import Cocoa

/// Manages a native global keyboard shortcut (⌃⌥Space) to toggle or peek the notch.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var action: (() -> Void)?
    private(set) var isRegistered = false

    func start(action: @escaping () -> Void) {
        self.action = action
        registerHotkey()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            registerHotkey()
        } else {
            unregisterHotkey()
        }
    }

    func stop() {
        unregisterHotkey()
        action = nil
    }

    private func registerHotkey() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerBlock: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                manager.trigger()
            }
            return noErr
        }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerBlock,
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        guard status == noErr else { return }

        // Signature "CNTH" (Codenotch Hotkey)
        let hotKeyID = EventHotKeyID(signature: OSType(0x434E5448), id: 1)
        // Spacebar key code is 49 (kVK_Space), modifiers: controlKey | optionKey
        let modifiers = UInt32(controlKey | optionKey)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        isRegistered = (registerStatus == noErr)
    }

    private func unregisterHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        isRegistered = false
    }

    private func trigger() {
        action?()
    }
}
