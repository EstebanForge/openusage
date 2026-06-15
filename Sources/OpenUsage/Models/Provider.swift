/// A data source that can register widgets it knows how to feed.
struct Provider: Identifiable, Hashable {
    let id: String
    let displayName: String
    let icon: IconSource
}
