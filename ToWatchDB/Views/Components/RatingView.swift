import SwiftUI

/// Five stars for a 0–10 rating: each star is 2 points. Clicking the current value clears it.
struct RatingView: View {
    let rating: Double?
    var onChange: (Double?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let value = Double(star * 2)
                Button {
                    onChange(rating == value ? nil : value)
                } label: {
                    Image(systemName: symbol(for: star))
                        .foregroundStyle(rating == nil ? Color.secondary : Color.yellow)
                }
                .buttonStyle(.plain)
                .help(rating == value ? "Clear rating" : "Rate \(star) of 5")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your rating")
        .accessibilityValue(rating.map { "\(Int($0 / 2)) of 5 stars" } ?? "Not rated")
        .accessibilityAdjustableAction { direction in
            let current = rating ?? 0
            switch direction {
            case .increment: onChange(min(current + 2, 10))
            case .decrement: onChange(current <= 2 ? nil : current - 2)
            @unknown default: break
            }
        }
    }

    private func symbol(for star: Int) -> String {
        let value = rating ?? 0
        if value >= Double(star * 2) { return "star.fill" }
        if value >= Double(star * 2 - 1) { return "star.leadinghalf.filled" }
        return "star"
    }
}
