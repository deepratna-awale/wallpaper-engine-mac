//
//  WorkingInProgress.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/21.
//

import SwiftUI

struct WorkingInProgress: View {
    
    @State var bigGearAngle = 0.0
    @State var smallGearAngle = 0.0
    
    var body: some View {
        VStack {
            ZStack {
                Image(systemName: "gearshape")
                    .font(.system(size: 48))
                    .rotationEffect(.degrees(bigGearAngle + 30))
                    .offset(x: -20, y: -10)
                Image(systemName: "gearshape")
                    .font(.system(size: 32, weight: .semibold))
                    .rotationEffect(.degrees(smallGearAngle))
                    .offset(x: 20, y: 10)
            }
            .padding()
            .onAppear {
                withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                    bigGearAngle = 360
                    smallGearAngle = -360
                }
            }
            Text("Working on it")
        }
    }
}

struct NumericSliderInput<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    @Binding var value: Value
    let range: ClosedRange<Value>
    let defaultValue: Value
    var step: Value.Stride?
    var displayScale = 1.0
    var suffix = ""
    var fractionDigits = 2
    var sliderWidth: CGFloat? = nil
    var fieldWidth: CGFloat = 64

    /// `TextField(value:format:)` only writes back on commit, so typing needed a click elsewhere to
    /// take effect and dragging the slider left the field stale. The text is mirrored manually to
    /// keep both directions live.
    @State private var text = ""
    @FocusState private var isEditing: Bool

    private var displayedValue: Double { Double(value) * displayScale }

    private func formatted(_ number: Double) -> String {
        String(format: "%.\(fractionDigits)f", number)
    }

    private func commit(_ string: String) {
        guard let parsed = Double(string.trimmingCharacters(in: .whitespaces)) else { return }
        let lowerBound = Double(range.lowerBound) * displayScale
        let upperBound = Double(range.upperBound) * displayScale
        value = Value(min(max(parsed, lowerBound), upperBound) / displayScale)
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }
            .frame(width: sliderWidth)
            .onTapGesture(count: 2) { value = defaultValue }

            HStack(spacing: 2) {
                TextField("", text: $text)
                    .focused($isEditing)
                    .multilineTextAlignment(.trailing)
                    .frame(width: fieldWidth)
                    .onChange(of: text) { _, newText in
                        if isEditing { commit(newText) }
                    }
                    .onSubmit { commit(text) }
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { text = formatted(displayedValue) }
        .onChange(of: value) { _, _ in
            if !isEditing { text = formatted(displayedValue) }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { text = formatted(displayedValue) }
        }
    }
}
