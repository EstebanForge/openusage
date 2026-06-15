import Foundation

/// Read-only catalog of providers and the widgets they register, built from the live
/// `ProviderRuntime`s at launch.
struct WidgetRegistry: Sendable {
    let providers: [Provider]
    let descriptors: [WidgetDescriptor]

    func descriptor(id: String) -> WidgetDescriptor? { descriptors.first { $0.id == id } }
    func provider(id: String) -> Provider? { providers.first { $0.id == id } }
    func descriptors(for providerID: String) -> [WidgetDescriptor] {
        descriptors.filter { $0.providerID == providerID }
    }

    @MainActor
    static func from(_ runtimes: [ProviderRuntime]) -> WidgetRegistry {
        let providers = runtimes.map(\.provider)
        let metrics = runtimes.flatMap(\.widgetDescriptors)
        return WidgetRegistry(providers: providers, descriptors: metrics)
    }
}
