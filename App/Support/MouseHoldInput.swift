import AppKit
import DeskKit

struct MouseHoldInput: HoldInputSource {
  var isHeld: Bool {
    NSEvent.pressedMouseButtons & 1 != 0
  }
}
