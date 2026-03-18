enum SecretNamespace {
    static let pluginPrefix = "piqley.plugins."
    static let pluginProtocolVersion = "pluginProtocolVersion"

    static func pluginKey(plugin: String, key: String) -> String {
        "\(pluginPrefix)\(plugin).\(key)"
    }
}
