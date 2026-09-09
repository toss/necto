//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// The controls from `WebPackages/Bridge/components.css`, in SwiftUI.
///
/// The shell is Swift and every plugin is CSS, so a component that exists in only one
/// of them is a component the two surfaces will disagree about. Each type here has a
/// class in `WebPackages/Bridge/components.css`, and both move together.
///
/// A stock control is not an option: `Toggle(.switch)` paints itself in the system
/// accent, `List` brings its own selection, and a toolbar item arrives wearing AppKit's
/// capsule. Each of those shipped here at least once.

// MARK: Button

/// `.necto-button`, with the `-quiet`, `-danger` and `-primary` variants.
///
/// Quiet until needed: a destructive action reads as plain text and only colours itself
/// when the pointer is on it.
struct NectoButtonStyle: ButtonStyle {
    let scale: CGFloat
    var quiet = false
    var danger = false
    /// The one action a screen is asking for. Everything else stays quiet.
    var primary = false

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: NectoTheme.radiusControl)

        return configuration.label
            .font(.necto(.label, scale: scale))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: NectoTheme.buttonHeight * scale)
            .background(background(isPressed: configuration.isPressed), in: shape)
            .overlay(shape.stroke(quiet || primary ? .clear : NectoTheme.borderStrong, lineWidth: 1))
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        if primary { return NectoTheme.background }
        if danger, isHovering { return NectoTheme.danger }
        return quiet ? NectoTheme.textSecondary : NectoTheme.text
    }

    private func background(isPressed: Bool) -> Color {
        if primary { return isPressed || isHovering ? NectoTheme.textSecondary : NectoTheme.accent }
        if isPressed { return NectoTheme.selected }
        if isHovering { return danger ? NectoTheme.danger.opacity(0.12) : NectoTheme.hover }
        return quiet ? .clear : NectoTheme.surface
    }
}

// MARK: Switch

/// `.necto-switch`. On or off, with the knob position carrying the state so the meaning
/// survives without the colour.
struct NectoSwitch: View {
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!isOn) } label: {
            Capsule()
                .fill(isOn ? NectoTheme.success.opacity(0.18) : NectoTheme.background)
                .overlay(Capsule().stroke(isOn ? NectoTheme.success : NectoTheme.borderStrong, lineWidth: 1))
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? NectoTheme.success : NectoTheme.textTertiary)
                        .frame(width: 12, height: 12)
                        .padding(2)
                }
                .frame(width: 30, height: 18)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

// MARK: Segmented

/// `.necto-segmented`. One choice from a short, fixed set; a longer or open-ended set is
/// a menu instead.
struct NectoSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    let scale: CGFloat
    var fontFamily: String? = nil
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 {
                    Rectangle().fill(NectoTheme.borderStrong).frame(width: 1)
                }
                Segment(
                    label: option.label,
                    isOn: option.value == selection,
                    scale: scale,
                    fontFamily: fontFamily
                ) { select(option.value) }
            }
        }
        .fixedSize()
        .overlay(
            RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                .stroke(NectoTheme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
    }

    private struct Segment: View {
        let label: String
        let isOn: Bool
        let scale: CGFloat
        let fontFamily: String?
        let select: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: select) {
                Text(label)
                    .font(.necto(.label, scale: scale, family: fontFamily))
                    .foregroundStyle(isOn || isHovering ? NectoTheme.text : NectoTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: NectoTheme.buttonHeight * scale)
                    .background(background)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }

        private var background: Color {
            if isOn { return NectoTheme.selected }
            return isHovering ? NectoTheme.hover : NectoTheme.surface
        }
    }
}

// MARK: Stepper

/// `.necto-stepper`. A number that is both typed and nudged.
///
/// A segmented Small/Medium/Large was here first. It could not answer "one point
/// bigger", which is the adjustment someone reading a log for an hour actually wants.
struct NectoStepper: View {
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let unit: String
    let scale: CGFloat
    var fontFamily: String? = nil
    let set: (CGFloat) -> Void

    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 0) {
            nudge("minus", to: value - step)
            Rectangle().fill(NectoTheme.borderStrong).frame(width: 1)

            HStack(spacing: 2) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .focused($isEditing)
                    .frame(width: 26 * scale)
                    .onSubmit { commit() }
                    // Typing a number nobody confirms should not be left on screen as
                    // if it had taken effect.
                    .onChange(of: isEditing) { _, editing in if !editing { commit() } }

                Text(unit).foregroundStyle(NectoTheme.textTertiary)
            }
            .font(.necto(.label, scale: scale, family: fontFamily))
            .foregroundStyle(NectoTheme.text)
            .padding(.horizontal, 8)
            .frame(height: NectoTheme.buttonHeight * scale)

            Rectangle().fill(NectoTheme.borderStrong).frame(width: 1)
            nudge("plus", to: value + step)
        }
        .fixedSize()
        .overlay(
            RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                .stroke(NectoTheme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
        .onAppear { text = display }
        .onChange(of: value) { _, _ in if !isEditing { text = display } }
    }

    private var display: String { String(Int(value)) }

    private func commit() {
        guard let typed = Double(text.trimmingCharacters(in: .whitespaces)) else {
            text = display
            return
        }

        // Shown from what was just accepted, not from `value`: this view still holds the
        // value it was made with, so reading it back here puts the old number on screen
        // next to text that has already resized.
        let accepted = min(max(CGFloat(typed).rounded(), range.lowerBound), range.upperBound)
        set(accepted)
        text = String(Int(accepted))
    }

    private func nudge(_ systemImage: String, to next: CGFloat) -> some View {
        Button { set(next) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9 * scale, weight: .medium))
                .foregroundStyle(NectoTheme.textSecondary)
                .frame(width: 22 * scale, height: NectoTheme.buttonHeight * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!range.contains(next))
    }
}
