import AppKit
import Carbon.HIToolbox
import Foundation

struct GlobalHotKey: Equatable {
    static let defaultSearch = GlobalHotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey)
    )
    static let defaultAppSearch = GlobalHotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(shiftKey | optionKey)
    )

    let keyCode: UInt32
    let modifiers: UInt32

    var isValid: Bool {
        hasRequiredModifier && !Self.modifierKeyCodes.contains(keyCode)
    }

    var displayString: String {
        var value = ""
        if containsModifier(cmdKey) {
            value += "⌘"
        }
        if containsModifier(shiftKey) {
            value += "⇧"
        }
        if containsModifier(optionKey) {
            value += "⌥"
        }
        if containsModifier(controlKey) {
            value += "⌃"
        }
        value += Self.keyName(for: keyCode)
        return value
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.supportedCarbonModifiers
    }

    init?(event: NSEvent) {
        let hotKey = GlobalHotKey(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.carbonModifiers(from: event.modifierFlags)
        )
        guard hotKey.isValid else { return nil }
        self = hotKey
    }

    private var hasRequiredModifier: Bool {
        modifiers & Self.supportedCarbonModifiers != 0
    }

    private func containsModifier(_ modifier: Int) -> Bool {
        modifiers & UInt32(modifier) != 0
    }

    private static let supportedCarbonModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    private static let modifierKeyCodes = Set<UInt32>([
        UInt32(kVK_Command),
        UInt32(kVK_Shift),
        UInt32(kVK_CapsLock),
        UInt32(kVK_Option),
        UInt32(kVK_Control),
        UInt32(kVK_RightCommand),
        UInt32(kVK_RightShift),
        UInt32(kVK_RightOption),
        UInt32(kVK_RightControl),
        UInt32(kVK_Function)
    ])

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0

        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }

        return modifiers
    }

    private static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_Escape): "Escape",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "Left Arrow",
        UInt32(kVK_RightArrow): "Right Arrow",
        UInt32(kVK_DownArrow): "Down Arrow",
        UInt32(kVK_UpArrow): "Up Arrow",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20"
    ]
}

final class GlobalHotKeyController {
    enum RegistrationError: LocalizedError {
        case invalid(GlobalHotKey)
        case unavailable(GlobalHotKey)
        case failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .invalid(hotKey):
                "The shortcut \(hotKey.displayString) is not valid. Use a non-modifier key with Command, Shift, Option, or Control."
            case let .unavailable(hotKey):
                "The shortcut \(hotKey.displayString) is already in use by another app or system service."
            case let .failed(status):
                "macOS could not register the shortcut. Carbon returned status \(status)."
            }
        }
    }

    private static let signature = OSType(0x41545448)
    private static let hotKeyExistsStatus = OSStatus(-9878)
    private static let hotKeyInvalidStatus = OSStatus(-9879)
    static let eventNotHandledStatus = OSStatus(eventNotHandledErr)

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return GlobalHotKeyController.eventNotHandledStatus }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return GlobalHotKeyController.eventNotHandledStatus }

        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
        guard GlobalHotKeyController.dispatchStatus(for: hotKeyID, controllerHotKeyIDValue: controller.hotKeyIDValue) == noErr else {
            return GlobalHotKeyController.eventNotHandledStatus
        }

        controller.action()
        return noErr
    }

    private let hotKeyIDValue: UInt32
    private let action: () -> Void
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var registeredHotKey: GlobalHotKey?

    init(hotKeyIDValue: UInt32 = 1, action: @escaping () -> Void) {
        self.hotKeyIDValue = hotKeyIDValue
        self.action = action
        installEventHandler()
    }

    static func dispatchStatus(for hotKeyID: EventHotKeyID, controllerHotKeyIDValue: UInt32) -> OSStatus {
        guard
            hotKeyID.signature == signature,
            hotKeyID.id == controllerHotKeyIDValue
        else {
            return eventNotHandledStatus
        }

        return noErr
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func configure(isEnabled: Bool, hotKey: GlobalHotKey) throws {
        guard isEnabled else {
            unregister()
            return
        }

        guard hotKey.isValid else {
            throw RegistrationError.invalid(hotKey)
        }

        guard registeredHotKey != hotKey else { return }

        let previousHotKey = registeredHotKey
        unregister()

        do {
            try register(hotKey)
        } catch {
            if let previousHotKey {
                try? register(previousHotKey)
            }
            throw error
        }
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    private func register(_ hotKey: GlobalHotKey) throws {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotKeyIDValue)
        var nextHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &nextHotKeyRef
        )

        guard status == noErr, let nextHotKeyRef else {
            if status == Self.hotKeyExistsStatus {
                throw RegistrationError.unavailable(hotKey)
            }
            if status == Self.hotKeyInvalidStatus {
                throw RegistrationError.invalid(hotKey)
            }
            throw RegistrationError.failed(status)
        }

        hotKeyRef = nextHotKeyRef
        registeredHotKey = hotKey
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredHotKey = nil
    }
}
