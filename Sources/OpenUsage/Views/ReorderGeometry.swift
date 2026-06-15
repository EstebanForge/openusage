import SwiftUI

struct ReorderLift {
    enum Payload {
        case dashboardProvider(provider: Provider, plan: String?, rows: [WidgetData])
        case dashboardMetric(data: WidgetData)
        case customizeProvider(provider: Provider, rows: [String])
        case customizeMetric(title: String)
    }

    let id: String
    let payload: Payload
    let sourceFrame: CGRect
    let touchOffset: CGPoint
    var location: CGPoint
}

struct ReorderLiftPreview: View {
    let lift: ReorderLift

    var body: some View {
        preview
            .frame(width: lift.sourceFrame.width)
            .scaleEffect(1.025)
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            .position(
                x: lift.location.x - lift.touchOffset.x + lift.sourceFrame.width / 2,
                y: lift.location.y - lift.touchOffset.y + lift.sourceFrame.height / 2
            )
            .animation(.none, value: lift.location)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var preview: some View {
        switch lift.payload {
        case .dashboardProvider(let provider, let plan, let rows):
            dashboardProviderPreview(provider: provider, plan: plan, rows: rows)
        case .dashboardMetric(let data):
            dashboardMetricPreview(data)
        case .customizeProvider(let provider, let rows):
            customizeProviderPreview(provider: provider, rows: rows)
        case .customizeMetric(let title):
            customizeMetricPreview(title)
        }
    }

    private func dashboardProviderPreview(provider: Provider, plan: String?, rows: [WidgetData]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ProviderSectionHeader(provider: provider, plan: plan)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    WidgetRowView(data: row)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Theme.liftedCardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func dashboardMetricPreview(_ data: WidgetData) -> some View {
        WidgetRowView(data: data)
            .background(Theme.liftedCardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
    }

    private func customizeProviderPreview(provider: Provider, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProviderSectionHeader(provider: provider) {
                ReorderGrip()
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, title in
                    HStack(spacing: 10) {
                        ReorderGrip()
                        Text(title)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Capsule()
                            .fill(.quaternary)
                            .frame(width: 28, height: 16)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .background(Theme.liftedCardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func customizeMetricPreview(_ title: String) -> some View {
        HStack(spacing: 10) {
            ReorderGrip()
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Capsule()
                .fill(.quaternary)
                .frame(width: 28, height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.liftedCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

}

/// Lightweight in-view geometry used for reordering inside the menu-bar popover.
///
/// This deliberately avoids SwiftUI's pasteboard-backed `.draggable` / `.dropDestination` APIs, which are
/// unreliable in this popover. A plain `DragGesture` stays inside the SwiftUI view tree: we record row frames,
/// compare the pointer location to those frames, and then mutate `LayoutStore` directly.
struct ReorderFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func reorderFrame(id: String, in coordinateSpace: CoordinateSpace) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReorderFramePreferenceKey.self,
                    value: [id: proxy.frame(in: coordinateSpace)]
                )
            }
        )
    }
}

/// The shared drag-to-reorder gesture used by both the dashboard list and the Customize screen, for both
/// provider headers and metric rows. The gesture body (lift tracking, target hit-testing, spring + haptic)
/// lives here once; each caller supplies only what differs: the active-row binding, the lift builder, the
/// current ordered ids, and the reorder action.
@MainActor
func reorderDragGesture(
    id: String,
    coordinateSpaceName: String,
    rowFrames: [String: CGRect],
    active: Binding<String?>,
    lift: Binding<ReorderLift?>,
    makeLift: @escaping (DragGesture.Value) -> ReorderLift?,
    orderedIDs: @escaping () -> [String],
    reorder: @escaping (_ target: String) -> Bool
) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpaceName))
        .onChanged { value in
            active.wrappedValue = id
            if lift.wrappedValue?.id != id, let newLift = makeLift(value) {
                lift.wrappedValue = newLift
            }
            lift.wrappedValue?.location = value.location
            guard let target = reorderTarget(
                at: value.location,
                in: rowFrames,
                excluding: id,
                orderedIDs: orderedIDs()
            ) else { return }
            var moved = false
            withAnimation(Motion.spring) {
                moved = reorder(target)
            }
            if moved { Haptics.snap() }
        }
        .onEnded { _ in
            active.wrappedValue = nil
            lift.wrappedValue = nil
        }
}

func reorderTarget(
    at location: CGPoint,
    in frames: [String: CGRect],
    excluding draggedID: String,
    orderedIDs: [String]
) -> String? {
    guard let from = orderedIDs.firstIndex(of: draggedID) else { return nil }
    let crossingThreshold = 0.20

    for id in orderedIDs where id != draggedID {
        guard let to = orderedIDs.firstIndex(of: id),
              let frame = frames[id],
              frame.insetBy(dx: 0, dy: -2).contains(location)
        else { continue }

        // Reorder only after crossing partway into the target row. This avoids the jumpy feel where a row moves
        // as soon as the pointer barely enters a neighbor, while still feeling less delayed than the midpoint.
        if to > from {
            return location.y >= frame.minY + frame.height * crossingThreshold ? id : nil
        } else {
            return location.y <= frame.maxY - frame.height * crossingThreshold ? id : nil
        }
    }

    return nil
}
