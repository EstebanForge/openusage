import SwiftUI

/// Synthetic per-provider "Plan" tile: shows `ProviderSnapshot.plan` as a text-only row when enabled.
enum PlanWidget {
    static let metricLabel = "Plan"
    static let title = "Plan"

    static func descriptorID(for providerID: String) -> String { "\(providerID).plan" }

    static func isPlan(_ descriptor: WidgetDescriptor) -> Bool {
        descriptor.id == descriptorID(for: descriptor.providerID)
    }

    static func descriptor(for provider: Provider) -> WidgetDescriptor {
        WidgetDescriptor(
            id: descriptorID(for: provider.id),
            providerID: provider.id,
            metricLabel: metricLabel,
            sample: WidgetData(
                title: title,
                icon: provider.icon,
                kind: .count,
                used: 0,
                limit: nil
            )
        )
    }
}
