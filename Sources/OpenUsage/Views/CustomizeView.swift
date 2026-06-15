import SwiftUI

/// The Customize screen. One block per enabled provider: a draggable header (reorders whole providers) over a
/// rounded card of metric rows, each a native `Toggle` with a drag grip (reorders metrics within that provider).
/// The provider is the group; each metric is a toggle inside it — so heterogeneous metric sets (Claude has many,
/// Grok has two) all read the same way.
///
/// Reordering uses `DragGesture` plus local row geometry. That keeps movement inside the menu-bar popover instead
/// of relying on SwiftUI's pasteboard-backed drag/drop session, which does not engage reliably here.
struct CustomizeView: View {
    @Environment(LayoutStore.self) private var layout
    @Binding var contentHeight: CGFloat
    @Binding var hasMeasuredContent: Bool
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var activeProviderID: String?
    @State private var activeMetricID: String?
    @State private var hoveredMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private var isReordering: Bool { activeProviderID != nil || activeMetricID != nil }

    var body: some View {
        scrollContent
        .frame(maxWidth: .infinity)
    }

    /// Fills the region the dashboard's pinned footer leaves; reports its content height up so
    /// `DashboardView` can clamp the popover. The native scroll edge effect handles the bar transition.
    ///
    /// The scroll edge effect needs the scroll view to keep a vertical scroller, so we don't hide
    /// indicators (that would kill the effect). `invisibleOverlayScroller()` instead keeps the overlay
    /// scroller (which reserves no gutter) and just makes it invisible: effect intact, no visible bar.
    private var scrollContent: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newValue in
                    if newValue > 0, !isReordering {
                        contentHeight = newValue
                        hasMeasuredContent = true
                    }
                }
                .invisibleOverlayScroller()
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if layout.customizeGroups.isEmpty {
            VStack(spacing: 6) {
                Text("No providers connected")
                    .font(.callout)
                Text("Turn providers on in Settings → Providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            // Same section rhythm as the dashboard list (both read the density setting).
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                ForEach(layout.customizeGroups) { group in
                    providerBlock(group)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .animation(Motion.spring, value: layout.customizeGroups.map(\.provider.id))
        }
    }

    private func providerBlock(_ group: ProviderMetrics) -> some View {
        // Same header→card gap as the dashboard section (`WidgetGroupedListView`).
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            providerHeader(group)
            metricCard(group)
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: .named(reorderSpaceName))
    }

    private func providerHeader(_ group: ProviderMetrics) -> some View {
        ProviderSectionHeader(provider: group.provider) {
            ReorderGrip()
        }
        // Align the header with the metric card's rows: rows are inset 12pt inside the card and the
        // header carries 4pt internally, so +8 lines the provider name up with the row grip (and the
        // header grip with the toggles) — the same inset on both edges.
        .padding(.horizontal, 8)
        .highPriorityGesture(providerDragGesture(for: group))
    }

    private func metricCard(_ group: ProviderMetrics) -> some View {
        VStack(spacing: 0) {
            ForEach(group.metrics) { metric in
                metricRow(metric, in: group.provider.id, metricIDs: group.metrics.map(\.id))
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricRow(_ metric: WidgetDescriptor, in providerID: String, metricIDs: [String]) -> some View {
        let isActive = activeMetricID == metric.id
        return HStack(spacing: 10) {
            // Grip + label form the drag handle; the trailing pin + toggle stay normal tappable controls.
            HStack(spacing: 10) {
                ReorderGrip()
                Text(metric.title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(metricDragGesture(for: metric.id, providerID: providerID, metricIDs: metricIDs))

            pinButton(metric)

            Toggle("", isOn: Binding(
                get: { layout.isMetricEnabled(metric.id) },
                set: { layout.setMetricEnabled(metric.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
        .contentShape(Rectangle())
        .opacity(isActive ? 0 : 1)
        .onHover { hovering in
            if hovering {
                hoveredMetricID = metric.id
            } else if hoveredMetricID == metric.id {
                hoveredMetricID = nil
            }
        }
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    /// The pin-to-menu-bar control on a metric row: a filled pin when pinned (always shown), an outline
    /// pin on row hover otherwise. At a cap the pin dims but stays clickable — a denied click routes
    /// through `notePinDenied`, which surfaces the reason in the footer (WhatsApp-style feedback)
    /// instead of silently doing nothing.
    @ViewBuilder
    private func pinButton(_ metric: WidgetDescriptor) -> some View {
        let pinned = layout.isPinned(metric.id)
        let blocked = !layout.canPin(metric.id)   // false when pinned, so unpin always works
        let visible = pinned || hoveredMetricID == metric.id
        // No app haptic here: the physical click already plays its own press/release haptics, and an
        // added pulse at mouse-up stacks against the release click and reads as a double vibration.
        Button {
            if blocked {
                layout.notePinDenied(metric.id)
            } else {
                layout.togglePin(metric.id)
            }
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
        .opacity(visible ? (blocked ? 0.35 : 1) : 0)
        .allowsHitTesting(visible)
        .help(pinHelp(metric))
        .animation(Motion.spring, value: visible)
        .animation(Motion.spring, value: pinned)
    }

    private func pinHelp(_ metric: WidgetDescriptor) -> String {
        if layout.isPinned(metric.id) { return "Unpin" }
        return layout.pinDenialReason(metric.id) ?? "Pin to menu bar"
    }

    private func providerDragGesture(for group: ProviderMetrics) -> some Gesture {
        reorderDragGesture(
            id: group.provider.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, value: $0) },
            orderedIDs: { layout.customizeGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: group.provider.id, target: $0) }
        )
    }

    private func metricDragGesture(for metricID: String, providerID: String, metricIDs: [String]) -> some Gesture {
        reorderDragGesture(
            id: metricID,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(metricID: metricID, value: $0) },
            orderedIDs: { metricIDs },
            reorder: { layout.reorderMetric(dragged: metricID, target: $0, in: providerID) }
        )
    }

    private func makeProviderLift(for group: ProviderMetrics, value: DragGesture.Value) -> ReorderLift? {
        guard let sourceFrame = rowFrames[group.provider.id] else { return nil }
        return ReorderLift(
            id: group.provider.id,
            payload: .customizeProvider(
                provider: group.provider,
                rows: group.metrics.map(\.title)
            ),
            sourceFrame: sourceFrame,
            touchOffset: CGPoint(
                x: value.startLocation.x - sourceFrame.minX,
                y: value.startLocation.y - sourceFrame.minY
            ),
            location: value.location
        )
    }

    private func makeMetricLift(metricID: String, value: DragGesture.Value) -> ReorderLift? {
        guard let sourceFrame = rowFrames[metricID],
              let title = layout.orderedSupportedMetrics(for: sourceFrameMetricProviderID(metricID)).first(where: { $0.id == metricID })?.title
        else { return nil }
        return ReorderLift(
            id: metricID,
            payload: .customizeMetric(title: title),
            sourceFrame: sourceFrame,
            touchOffset: CGPoint(
                x: value.startLocation.x - sourceFrame.minX,
                y: value.startLocation.y - sourceFrame.minY
            ),
            location: value.location
        )
    }

    private func sourceFrameMetricProviderID(_ metricID: String) -> String {
        layout.customizeGroups.first { group in
            group.metrics.contains { $0.id == metricID }
        }?.provider.id ?? ""
    }
}
