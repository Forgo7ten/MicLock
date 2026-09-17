import SwiftUI

@MainActor
struct RecentAudioEventRow: View {

    enum Style: Equatable {
        case compact
        case detailed
    }

    let event: RecentAudioEvent
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.titleText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer()

                Text(event.occurredAt, style: .time)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(event.transitionText)
                .font(.caption)
                .lineLimit(style == .compact ? 1 : 2)

            if style == .detailed {
                Text(event.reasonText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
