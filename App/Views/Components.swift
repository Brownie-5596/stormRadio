import SwiftUI
import StormRadioCore

/// Picker for how something is announced.
struct ModePicker: View {
    var title = "Announce"
    @Binding var mode: AnnounceMode

    var body: some View {
        Picker(title, selection: $mode) {
            ForEach(AnnounceMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
        }
    }
}

/// Picker for a tone with a play button.
struct TonePicker: View {
    @EnvironmentObject var model: AppModel
    var title = "Sound"
    @Binding var tone: ToneID

    var body: some View {
        HStack {
            Picker(title, selection: $tone) {
                ForEach(ToneID.allCases, id: \.self) { t in Text(t.label).tag(t) }
            }
            Button {
                model.speech.preview(tone: tone)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(tone == .none)
        }
    }
}

/// Distance in miles with a stepper and slider. 0 can mean "only when inside".
struct MilesField: View {
    var title: String
    @Binding var miles: Double
    var range: ClosedRange<Double> = 0...300
    var zeroLabel: String? = "only when you're inside it"

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(miles == 0 && zeroLabel != nil ? zeroLabel! : "\(Int(miles)) mi")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Slider(value: $miles, in: range, step: 1)
                Stepper("", value: $miles, in: range, step: 1).labelsHidden()
            }
        }
    }
}

struct PriorityStepper: View {
    var title = "Priority"
    @Binding var priority: Int

    var body: some View {
        Stepper(value: $priority, in: 1...10) {
            HStack {
                Text(title)
                Spacer()
                Text("\(priority)").foregroundStyle(.secondary)
            }
        }
    }
}

struct IntStepper: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var unit = ""

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)\(unit)").foregroundStyle(.secondary)
            }
        }
    }
}

/// Comma-separated list of integers (e.g. lead times "30, 15, 5").
struct IntListField: View {
    var title: String
    @Binding var values: [Int]
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("30, 15, 5", text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .onSubmit(commit)
                .frame(maxWidth: 160)
        }
        .onAppear { text = values.map(String.init).joined(separator: ", ") }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let v = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { $0 > 0 }
        values = Array(Set(v)).sorted(by: >)
        text = values.map(String.init).joined(separator: ", ")
    }
}

/// Comma-separated list of strings.
struct StringListField: View {
    var title: String
    var placeholder: String
    @Binding var values: [String]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onSubmit(commit)
        }
        .onAppear { text = values.joined(separator: ", ") }
        .onDisappear(perform: commit)
    }

    private func commit() {
        values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Small colored label like "Speak", "Tone".
struct Pill: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
