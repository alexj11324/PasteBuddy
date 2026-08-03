public enum PasteBuddyFeatureAvailability {
    /// Temporarily disabled across macOS, iOS, and app extensions.
    /// Keep the implementation and persisted pairing configuration intact so
    /// the feature can be restored without a migration.
    public static let irohClipboardSync = false
}
