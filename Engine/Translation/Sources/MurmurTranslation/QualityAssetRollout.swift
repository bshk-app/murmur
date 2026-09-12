extension QualityModelAssetRegistry {
    /// Add immutable published asset descriptors only after qualification.
    /// Merely registering bytes does not select a profile or start a download.
    public static let current = try! QualityModelAssetRegistry(additionalAssets: [])
}
