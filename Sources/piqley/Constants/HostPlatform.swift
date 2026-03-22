enum HostPlatform {
    static var current: String {
        #if os(macOS) && arch(arm64)
            return "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
            return "linux-amd64"
        #elseif os(Linux) && arch(arm64)
            return "linux-arm64"
        #else
            fatalError("Unsupported platform")
        #endif
    }
}
