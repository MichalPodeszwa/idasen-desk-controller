import DeskKit
import SwiftUI

struct ControlsSection: View {
  @Environment(AppModel.self) private var model
  @State private var target = 0.0
  @State private var targetText = ""
  @State private var isEditingTarget = false
  @FocusState private var fieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        HoldButton(direction: .down)
        HoldButton(direction: .up)
        Button {
          model.stop()
        } label: {
          Label("Stop", systemImage: "stop.fill")
            .frame(minHeight: 28)
        }
        .tint(.red)
        .keyboardShortcut(.escape, modifiers: [])
      }
      HStack(spacing: 8) {
        Slider(
          value: $target, in: model.minCm...model.maxCm, step: 0.1,
          onEditingChanged: { isEditingTarget = $0 }
        )
        .onChange(of: target) {
          if !fieldFocused { targetText = Formatting.cm(target) }
        }
        TextField("cm", text: $targetText)
          .focused($fieldFocused)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 52)
          .onChange(of: targetText) {
            guard fieldFocused, let cm = HeightInput.parse(targetText) else { return }
            target = min(max(cm, model.minCm), model.maxCm)
          }
          .onSubmit(go)
        Button("Go", action: go)
      }
    }
    .onAppear { syncTarget() }
    .onChange(of: model.controller.heightRaw) { syncTarget() }
  }

  private func go() {
    model.moveTo(cm: HeightInput.parse(targetText) ?? target)
  }

  private func syncTarget() {
    guard !isEditingTarget, !fieldFocused, !model.isMoving, let height = model.heightCm else {
      return
    }
    target = (height * 10).rounded() / 10
    targetText = Formatting.cm(target)
  }
}

struct HoldButton: View {
  let direction: MoveDirection
  @Environment(AppModel.self) private var model
  @State private var pressed = false

  var body: some View {
    Image(systemName: direction == .up ? "chevron.up" : "chevron.down")
      .font(.title2.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: 36)
      .background(
        pressed ? Color.accentColor : Color.secondary.opacity(0.2),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .foregroundStyle(pressed ? Color.white : Color.primary)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !pressed else { return }
            pressed = true
            model.beginHold(direction)
          }
          .onEnded { _ in
            pressed = false
            model.endHold()
          }
      )
      .accessibilityLabel(direction == .up ? "Hold to raise" : "Hold to lower")
      .accessibilityAddTraits(.isButton)
  }
}
