import DeskKit
import SwiftUI

struct PositionsSection: View {
  @Environment(AppModel.self) private var model
  @State private var isEditing = false
  @State private var newName = ""
  @State private var newHeightText = ""
  @State private var saveError: String?
  @State private var listHeight: CGFloat = 0

  var body: some View {
    let store = model.controller.positions
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Positions").font(.subheadline.bold())
        Spacer()
        if !store.positions.isEmpty {
          Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
            .buttonStyle(.borderless)
        }
      }
      if let warning = store.warning {
        Text(Formatting.message(for: warning)).font(.caption).foregroundStyle(.orange)
      }
      if store.positions.isEmpty {
        Text("No saved positions yet").font(.callout).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(store.positions.enumerated()), id: \.element.id) { index, position in
              if isEditing {
                PositionEditRow(position: position, index: index, count: store.positions.count)
              } else {
                PositionRow(position: position, index: index)
              }
            }
          }
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            listHeight = $0
          }
        }
        // A ScrollView has no ideal height of its own, so the popover window would not grow as rows are added.
        .frame(height: min(listHeight, 190))
        .scrollBounceBehavior(.basedOnSize)
      }
      saveRow
    }
    .onChange(of: store.positions.isEmpty) { _, isEmpty in
      if isEmpty { isEditing = false }
    }
  }

  private var saveRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        TextField("Name", text: $newName)
          .onSubmit(save)
        TextField("current", text: $newHeightText)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 60)
          .onSubmit(save)
          .help("Height in cm. Leave empty to use the current height")
        Button("Save", action: save)
          .disabled(!model.isConnected && newHeightText.isEmpty)
      }
      if let saveError {
        Text(saveError).font(.caption).foregroundStyle(.red)
      }
    }
  }

  private func save() {
    saveError = model.savePosition(named: newName, heightText: newHeightText)
    if saveError == nil {
      newName = ""
      newHeightText = ""
    }
  }
}

private struct PositionRow: View {
  let position: Position
  let index: Int
  @Environment(AppModel.self) private var model

  var body: some View {
    Button {
      model.move(to: position)
    } label: {
      HStack {
        Text(position.name).lineLimit(1)
        Spacer()
        Text(Formatting.cm(model.cm(forRaw: position.height.raw)) + " cm")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        if index < 9 {
          Text("⌘\(index + 1)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help("Press ⌘\(index + 1) to move here")
        }
      }
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!model.isConnected)
    .keyboardShortcut(Self.shortcut(for: index))
  }

  private static func shortcut(for index: Int) -> KeyboardShortcut? {
    guard index < 9, let key = String(index + 1).first else { return nil }
    return KeyboardShortcut(KeyEquivalent(key), modifiers: .command)
  }
}

private struct PositionEditRow: View {
  private enum Field {
    case name
    case height
  }

  let position: Position
  let index: Int
  let count: Int
  @Environment(AppModel.self) private var model
  @State private var name: String
  @State private var heightText: String
  @State private var error: String?
  @FocusState private var focus: Field?

  init(position: Position, index: Int, count: Int) {
    self.position = position
    self.index = index
    self.count = count
    _name = State(initialValue: position.name)
    _heightText = State(initialValue: "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        TextField("Name", text: $name)
          .focused($focus, equals: .name)
          .onSubmit(commitName)
        TextField("cm", text: $heightText)
          .focused($focus, equals: .height)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 56)
          .onSubmit(commitHeight)
        Button {
          error = model.reorder(position, toIndex: index - 1)
        } label: {
          Image(systemName: "chevron.up")
        }
        .disabled(index == 0)
        Button {
          error = model.reorder(position, toIndex: index + 1)
        } label: {
          Image(systemName: "chevron.down")
        }
        .disabled(index == count - 1)
        Button {
          error = model.remove(position)
        } label: {
          Image(systemName: "trash")
        }
      }
      .buttonStyle(.borderless)
      let slug = model.controller.positions.usableSlug(of: position)
      if !slug.isEmpty {
        Text(slug)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .onDisappear {
      commitName()
      commitHeight()
    }
    .onAppear { heightText = Formatting.cm(model.cm(forRaw: position.height.raw)) }
    .onChange(of: focus) { old, _ in
      switch old {
      case .name: commitName()
      case .height: commitHeight()
      case nil: break
      }
    }
    .onChange(of: model.settings.calibrationMM) {
      heightText = Formatting.cm(model.cm(forRaw: position.height.raw))
    }
  }

  private func commitName() {
    error = model.rename(position, to: name)
  }

  private func commitHeight() {
    guard let cm = HeightInput.parse(heightText) else {
      error = "Enter a height in cm"
      return
    }
    error = model.setHeight(position, cm: cm)
  }
}
