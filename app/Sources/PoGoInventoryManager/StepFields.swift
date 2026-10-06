import SwiftUI

// The input controls the settings are built from: labelled fields, steppers and the tag name and value fields.

/// The little grey caption above a field.
struct FieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
    }
}

/// Caption above a control.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            content
        }
    }
}

/// The box every input sits in: 32 points tall, the input colour, a hairline border.
struct DesignField<Content: View>: View {
    var height: CGFloat = 32
    var leading: CGFloat = 10
    var trailing: CGFloat = 10
    var focused = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(height: height)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.border, lineWidth: focused ? 1.5 : 1)
            }
    }
}

/// A number with the two little arrows on the right, as in the design.
struct StepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var suffix: String?
    /// What to write instead of 0 ("all" for "how many duplicate groups to check").
    var zeroLabel: String?
    var height: CGFloat = 32
    var width: CGFloat?

    private var text: String {
        if value == 0, let zeroLabel { return zeroLabel }
        return suffix.map { "\(value) \($0)" } ?? "\(value)"
    }

    var body: some View {
        DesignField(height: height, leading: 10, trailing: 6) {
            HStack(spacing: 6) {
                Text(text)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: Double(value)))
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    caret("chevron.up") { value = min(range.upperBound, value + step) }
                    caret("chevron.down") { value = max(range.lowerBound, value - step) }
                }
            }
        }
        .frame(width: width)
        .animation(.easeOut(duration: 0.15), value: value)
    }

    private func caret(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(Theme.muted)
                .frame(width: 14, height: 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

/// A tag: the dot in the colour it has in the game, and its name. Clicking the dot opens the palette.
struct TagNameField: View {
    @Binding var color: TagColor
    @Binding var name: String
    var placeholder: String = ""

    var body: some View {
        DesignField {
            HStack(spacing: 8) {
                ColorDotButton(color: $color, size: 8)
                TextField(placeholder, text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            }
        }
    }
}

/// A read-only tag field (for a name the user doesn't set here).
struct TagValueField: View {
    let color: Color
    let name: String

    var body: some View {
        DesignField {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).font(.system(size: 13))
            }
        }
    }
}
