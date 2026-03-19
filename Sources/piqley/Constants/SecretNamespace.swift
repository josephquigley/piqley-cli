enum SecretNamespace {
    static let pluginPrefix = "piqley.plugins."
    static let pluginSchemaVersion = "pluginSchemaVersion"

    static func pluginKey(plugin: String, key: String) -> String {
        "\(pluginPrefix)\(plugin).\(key)"
    }
}
