import CFNetwork
import Darwin
import Foundation
import Network
import os
import OSLog

/// Synchronizes active OS manual HTTP/HTTPS/SOCKS proxy settings (`CFNetworkCopySystemProxySettings`)
/// into `URLSessionConfiguration.proxyConfigurations` (and, via the WebKit extension in
/// `CleanroomWebKitSession.swift`, into `WKWebsiteDataStore.proxyConfigurations`) with `allowFailover = false`.
///
/// Apple's `NWURLSession` races HTTP/3 (QUIC over UDP/443) directly out `en0` around non-TUN
/// system HTTP proxies (such as macOS Clash/Mihomo or iOS manual Wi-Fi proxies) while sending
/// HTTP/1.1/2 TCP traffic through the proxy. Binding an explicit `ProxyConfiguration(httpCONNECTProxy:)`
/// with `allowFailover = false` forces HTTP/3 and HTTP/1.1 hosts onto the exact same TCP proxy path
/// with zero TUN driver required.
public enum SystemProxyBridge {
    /// Parsed IPv4 or IPv6 CIDR block backed by `inet_pton` bitmask matching (zero string-prefix heuristics).
    public struct CIDRBlock: Equatable, Hashable, Sendable {
        public enum Address: Equatable, Hashable, Sendable {
            case ipv4(UInt32)
            case ipv6(UInt64, UInt64)
        }

        public let network: Address
        public let prefixLength: UInt8

        public static func parse(_ raw: String) -> CIDRBlock? {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let prefix = UInt8(parts[1]) else {
                return nil
            }
            let ipPart = String(parts[0])
            if let v4 = parseIPv4(ipPart), prefix <= 32 {
                let mask = ipv4Mask(prefix)
                return CIDRBlock(network: .ipv4(v4 & mask), prefixLength: prefix)
            }
            if let (hi, lo) = parseIPv6(ipPart), prefix <= 128 {
                let (mHi, mLo) = ipv6Mask(prefix)
                return CIDRBlock(network: .ipv6(hi & mHi, lo & mLo), prefixLength: prefix)
            }
            return nil
        }

        public func contains(ipString: String) -> Bool {
            let trimmed = ipString.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\r\n"))
            switch network {
            case .ipv4(let net):
                guard let ip = Self.parseIPv4(trimmed) else { return false }
                let mask = Self.ipv4Mask(prefixLength)
                return (ip & mask) == net
            case .ipv6(let netHi, let netLo):
                guard let (hi, lo) = Self.parseIPv6(trimmed) else { return false }
                let (mHi, mLo) = Self.ipv6Mask(prefixLength)
                return (hi & mHi) == netHi && (lo & mLo) == netLo
            }
        }

        /// True only when this entire CIDR block is strictly contained within RFC1918, loopback,
        /// link-local, or IPv6 ULA/loopback/link-local private space (rejects e.g. `172.2.0.0/16` and `10.0.0.0/4`).
        public var isStrictlyPrivateOrLocal: Bool {
            switch network {
            case .ipv4(let net):
                let privateRanges: [(UInt32, UInt8)] = [
                    (0x7F00_0000, 8),   // 127.0.0.0/8 loopback
                    (0x0A00_0000, 8),   // 10.0.0.0/8 RFC1918
                    (0xAC10_0000, 12),  // 172.16.0.0/12 RFC1918 (172.16.0.0 - 172.31.255.255)
                    (0xC0A8_0000, 16),  // 192.168.0.0/16 RFC1918
                    (0xA9FE_0000, 16)   // 169.254.0.0/16 link-local
                ]
                return privateRanges.contains { base, minPrefix in
                    prefixLength >= minPrefix && (net & Self.ipv4Mask(minPrefix)) == base
                }
            case .ipv6(let netHi, let netLo):
                if prefixLength == 128 && netHi == 0 && netLo == 1 {
                    return true // ::1/128 loopback
                }
                if prefixLength >= 7 && (netHi & 0xFE00_0000_0000_0000) == 0xFC00_0000_0000_0000 {
                    return true // fc00::/7 ULA
                }
                if prefixLength >= 10 && (netHi & 0xFFC0_0000_0000_0000) == 0xFE80_0000_0000_0000 {
                    return true // fe80::/10 link-local
                }
                return false
            }
        }

        private static func ipv4Mask(_ prefix: UInt8) -> UInt32 {
            prefix == 0 ? 0 : (~UInt32(0) << (32 - UInt32(prefix)))
        }

        private static func ipv6Mask(_ prefix: UInt8) -> (UInt64, UInt64) {
            if prefix == 0 { return (0, 0) }
            if prefix <= 64 {
                return (~UInt64(0) << (64 - UInt64(prefix)), 0)
            }
            return (~UInt64(0), ~UInt64(0) << (128 - UInt64(prefix)))
        }

        private static func parseIPv4(_ str: String) -> UInt32? {
            var addr = in_addr()
            guard str.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
            return UInt32(bigEndian: addr.s_addr)
        }

        private static func parseIPv6(_ str: String) -> (UInt64, UInt64)? {
            var addr = in6_addr()
            guard str.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
            return withUnsafeBytes(of: &addr) { raw in
                var hi: UInt64 = 0
                var lo: UInt64 = 0
                for i in 0..<8 { hi = (hi << 8) | UInt64(raw[i]) }
                for i in 8..<16 { lo = (lo << 8) | UInt64(raw[i]) }
                return (hi, lo)
            }
        }
    }

    public struct ProxyDescriptor: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case httpConnect
            case socks5
        }

        public let kind: Kind
        public let host: String
        public let port: UInt16
        public let excludedDomains: [String]
        public let excludedCIDRs: [CIDRBlock]
        public let excludeSimpleHostnames: Bool

        public init(
            kind: Kind,
            host: String,
            port: UInt16,
            excludedDomains: [String],
            excludedCIDRs: [CIDRBlock] = [],
            excludeSimpleHostnames: Bool = false
        ) {
            self.kind = kind
            self.host = host
            self.port = port
            self.excludedDomains = excludedDomains
            self.excludedCIDRs = excludedCIDRs
            self.excludeSimpleHostnames = excludeSimpleHostnames
        }

        /// Returns `true` when `url` matches an OS bypass rule (simple hostname, excluded domain suffix,
        /// or parsed IPv4/IPv6 CIDR exception) and must connect directly rather than via the proxy.
        public func shouldBypass(url: URL) -> Bool {
            guard let rawHost = url.host()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !rawHost.isEmpty else {
                return false
            }
            let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if excludeSimpleHostnames && !host.contains(".") && !host.contains(":") {
                return true
            }
            for domain in excludedDomains {
                if host == domain || host.hasSuffix(".\(domain)") {
                    return true
                }
            }
            for cidr in excludedCIDRs {
                if cidr.contains(ipString: host) {
                    return true
                }
            }
            return false
        }
    }

    public enum SessionProfile: Hashable, Sendable {
        case rangeTransfer
        case hlsStream
        case streamProber
        case mediaResolver
    }

    /// Reference-counted lease keeping a pooled `URLSession` alive for the full duration of a
    /// multi-request transfer or probe. If the proxy rotates while a lease is held, the retired
    /// session stays valid for new slice/segment tasks until the last active lease releases it,
    /// eliminating `Task created in a session that has been invalidated` crashes.
    public final class SessionLease: @unchecked Sendable {
        public let session: URLSession
        public let descriptor: ProxyDescriptor?
        private let releaseAction: @Sendable () -> Void
        private let released = OSAllocatedUnfairLock(initialState: false)

        public init(
            session: URLSession,
            descriptor: ProxyDescriptor? = nil,
            onRelease: @escaping @Sendable () -> Void = {}
        ) {
            self.session = session
            self.descriptor = descriptor
            self.releaseAction = onRelease
        }

        public func release() {
            let shouldRelease = released.withLock { already -> Bool in
                if already { return false }
                already = true
                return true
            }
            if shouldRelease {
                releaseAction()
            }
        }

        deinit {
            release()
        }
    }

    private final class ManagedSession: @unchecked Sendable {
        let descriptor: ProxyDescriptor?
        let session: URLSession
        var activeLeases: Int = 0
        var isRetired: Bool = false
        var didInvalidate: Bool = false

        init(descriptor: ProxyDescriptor?, session: URLSession) {
            self.descriptor = descriptor
            self.session = session
        }
    }

    private struct PoolKey: Hashable, Sendable {
        let profile: SessionProfile
        let isDirectBypass: Bool
    }

    static let logger = Logger(subsystem: "com.appautomaton.dysprosium", category: "SystemProxy")
    private static let sessionPoolLock = OSAllocatedUnfairLock<[PoolKey: ManagedSession]>(initialState: [:])

    private static func isLoopbackHost(_ host: String) -> Bool {
        let clean = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\r\n")).lowercased()
        if clean == "localhost" || clean == "::1" { return true }
        return CIDRBlock.parse("127.0.0.0/8")?.contains(ipString: clean) == true
    }

    /// Pure parser for a `CFNetworkCopySystemProxySettings()` dictionary so both runtime and tests
    /// share the exact same equivalence, auth/PAC safety bailouts, CIDR bitmask checks, and domain exclusions.
    public static func resolveDescriptor(from settings: [String: Any]) -> ProxyDescriptor? {
        func isEnabled(_ key: String) -> Bool {
            if let num = settings[key] as? NSNumber { return num.intValue != 0 }
            if let flag = settings[key] as? Bool { return flag }
            return false
        }
        func parsePort(_ key: String) -> UInt16? {
            guard let raw = (settings[key] as? NSNumber)?.intValue,
                  raw >= 1, raw <= 65535 else {
                return nil
            }
            return UInt16(raw)
        }
        func parseHost(_ key: String) -> String? {
            guard let raw = (settings[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return raw
        }
        func hasAuth(_ key: String) -> Bool {
            guard let raw = (settings[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !raw.isEmpty
        }

        // Never override dynamic PAC scripts or Keychain-authenticated corporate proxies (passwords
        // are omitted from `CFNetworkCopySystemProxySettings`, so overriding would cause HTTP 407).
        if isEnabled("ProxyAutoConfigEnable") {
            return nil
        }

        let httpsOn = isEnabled("HTTPSEnable")
        let httpOn = isEnabled("HTTPEnable")
        let socksOn = isEnabled("SOCKSEnable")

        let resolved: (ProxyDescriptor.Kind, String, UInt16)? = {
            if httpsOn || httpOn {
                if httpsOn && httpOn {
                    guard let httpsHost = parseHost("HTTPSProxy"),
                          let httpsPort = parsePort("HTTPSPort"),
                          let httpHost = parseHost("HTTPProxy"),
                          let httpPort = parsePort("HTTPPort"),
                          httpsHost.lowercased() == httpHost.lowercased(),
                          httpsPort == httpPort,
                          !hasAuth("HTTPSUser"),
                          !hasAuth("HTTPUser") else {
                        return nil
                    }
                    return (.httpConnect, httpsHost, httpsPort)
                }
                if httpsOn,
                   let host = parseHost("HTTPSProxy"),
                   let port = parsePort("HTTPSPort"),
                   !hasAuth("HTTPSUser") {
                    return (.httpConnect, host, port)
                }
                if httpOn,
                   let host = parseHost("HTTPProxy"),
                   let port = parsePort("HTTPPort"),
                   !hasAuth("HTTPUser") {
                    return (.httpConnect, host, port)
                }
                return nil
            }
            if socksOn,
               let host = parseHost("SOCKSProxy"),
               let port = parsePort("SOCKSPort"),
               !hasAuth("SOCKSUser") {
                return (.socks5, host, port)
            }
            return nil
        }()

        guard let (kind, host, port) = resolved else { return nil }
        let proxyIsLoopback = isLoopbackHost(host)

        var excluded: [String] = ["localhost", "127.0.0.1", "::1", "local"]
        var seen = Set(excluded)
        var excludedCIDRs: [CIDRBlock] = []
        var excludeSimpleHostnames = isEnabled("ExcludeSimpleHostnames")

        if let rawList = settings["ExceptionsList"] as? [String] {
            for entry in rawList {
                var clean = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if clean.isEmpty {
                    continue
                }
                if clean == "<local>" {
                    excludeSimpleHostnames = true
                    continue
                }
                if clean.contains("/") {
                    guard let cidr = CIDRBlock.parse(clean) else {
                        return nil
                    }
                    // `nw_proxy_config_add_excluded_domain` cannot represent CIDR exceptions for WebKit.
                    // Bail out for non-loopback proxies or any non-private CIDR; for loopback proxies
                    // (e.g. macOS Clash/Mihomo) with strictly RFC1918/local CIDRs, keep `excludedCIDRs`
                    // so `URLSession` honors them while WebKit stays protected from HTTP/3 QUIC leaks.
                    guard proxyIsLoopback && cidr.isStrictlyPrivateOrLocal else {
                        return nil
                    }
                    if !excludedCIDRs.contains(cidr) {
                        excludedCIDRs.append(cidr)
                    }
                    continue
                }
                while clean.hasPrefix("*.") {
                    clean = String(clean.dropFirst(2))
                }
                while clean.hasPrefix(".") {
                    clean = String(clean.dropFirst())
                }
                if !clean.isEmpty, seen.insert(clean).inserted {
                    excluded.append(clean)
                }
            }
        }
        return ProxyDescriptor(
            kind: kind,
            host: host,
            port: port,
            excludedDomains: excluded,
            excludedCIDRs: excludedCIDRs,
            excludeSimpleHostnames: excludeSimpleHostnames
        )
    }

    public static func currentDescriptor() -> ProxyDescriptor? {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return resolveDescriptor(from: raw)
    }

    public static func makeProxyConfigurations(for descriptor: ProxyDescriptor? = currentDescriptor()) -> [ProxyConfiguration] {
        guard let descriptor,
              let nwPort = NWEndpoint.Port(rawValue: descriptor.port) else {
            return []
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(descriptor.host), port: nwPort)
        var config: ProxyConfiguration
        switch descriptor.kind {
        case .httpConnect:
            config = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socks5:
            config = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        config.allowFailover = false
        config.excludedDomains = descriptor.excludedDomains
        return [config]
    }

    /// Applies a captured `ProxyDescriptor?` snapshot to `URLSessionConfiguration` (avoiding a
    /// second racy read of `CFNetworkCopySystemProxySettings`).
    public static func applyToURLSessionConfiguration(
        _ cfg: URLSessionConfiguration,
        descriptor: ProxyDescriptor? = currentDescriptor()
    ) {
        let configs = makeProxyConfigurations(for: descriptor)
        if !configs.isEmpty {
            cfg.proxyConfigurations = configs
        }
    }

    private static func makeConfiguration(for profile: SessionProfile, descriptor: ProxyDescriptor?) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        switch profile {
        case .rangeTransfer:
            cfg.httpMaximumConnectionsPerHost = 32
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60 * 60 * 6
            cfg.waitsForConnectivity = true
        case .hlsStream:
            cfg.httpMaximumConnectionsPerHost = 24
            cfg.timeoutIntervalForRequest = 30
        case .streamProber:
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 18
        case .mediaResolver:
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            cfg.urlCache = nil
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 20
        }
        applyToURLSessionConfiguration(cfg, descriptor: descriptor)
        return cfg
    }

    /// Builds an isolated, non-pooled ephemeral `URLSession` (for Private browsing resolves)
    /// honoring the exact same `shouldBypass(url:)` CIDR/domain bypass policy as pooled leases.
    /// Caller owns `invalidateAndCancel()` on release.
    public static func makeOneShotEphemeralSession(
        for profile: SessionProfile,
        targetURL: URL? = nil,
        descriptorOverride: ProxyDescriptor?? = nil
    ) -> URLSession {
        let rawSnapshot = descriptorOverride ?? currentDescriptor()
        let bypassed = targetURL.flatMap { url in rawSnapshot?.shouldBypass(url: url) } ?? false
        let effectiveDescriptor: ProxyDescriptor? = bypassed ? nil : rawSnapshot
        let cfg = makeConfiguration(for: profile, descriptor: effectiveDescriptor)
        return URLSession(configuration: cfg)
    }

    /// Acquires a reference-counted `SessionLease` bound to the single current `ProxyDescriptor?`
    /// snapshot for `profile`. If `targetURL` matches an excluded domain, simple hostname, or CIDR
    /// block on the active descriptor, a direct (bypass) session lease is returned instead.
    ///
    /// When the proxy rotates mid-operation, newly acquired leases immediately get a fresh session,
    /// while any displaced session stays valid for new tasks until all existing leases release it,
    /// at which point `finishTasksAndInvalidate()` is called cleanly.
    public static func acquireSessionLease(
        for profile: SessionProfile,
        targetURL: URL? = nil,
        descriptorOverride: ProxyDescriptor?? = nil
    ) -> SessionLease {
        let rawSnapshot = descriptorOverride ?? currentDescriptor()
        let bypassed = targetURL.flatMap { url in rawSnapshot?.shouldBypass(url: url) } ?? false
        let effectiveDescriptor: ProxyDescriptor? = bypassed ? nil : rawSnapshot
        let poolKey = PoolKey(profile: profile, isDirectBypass: bypassed)

        let (entry, immediateRetire): (ManagedSession, URLSession?) = sessionPoolLock.withLock { pool in
            if let cached = pool[poolKey], cached.descriptor == effectiveDescriptor {
                cached.activeLeases += 1
                return (cached, nil)
            }
            let cfg = makeConfiguration(for: profile, descriptor: effectiveDescriptor)
            let fresh = ManagedSession(descriptor: effectiveDescriptor, session: URLSession(configuration: cfg))
            fresh.activeLeases = 1

            var toInvalidate: URLSession?
            if let displaced = pool[poolKey] {
                displaced.isRetired = true
                if displaced.activeLeases == 0 && !displaced.didInvalidate {
                    displaced.didInvalidate = true
                    toInvalidate = displaced.session
                }
            }
            pool[poolKey] = fresh
            return (fresh, toInvalidate)
        }
        immediateRetire?.finishTasksAndInvalidate()

        return SessionLease(session: entry.session, descriptor: entry.descriptor) {
            let retiredSession: URLSession? = sessionPoolLock.withLock { _ in
                entry.activeLeases = max(0, entry.activeLeases - 1)
                if entry.isRetired && entry.activeLeases == 0 && !entry.didInvalidate {
                    entry.didInvalidate = true
                    return entry.session
                }
                return nil
            }
            retiredSession?.finishTasksAndInvalidate()
        }
    }
}
