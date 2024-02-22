//
//  Network.swift
//
//  Copyright © 2019-2024 Purgatory Design. Licensed under the MIT License.
//

import Foundation

public enum Network {

    public static var hostName: String? {
        #if os(Linux)
        let maxHostNameLength = Int(HOST_NAME_MAX) + 1
        #else
        let maxHostNameLength = Int(_POSIX_HOST_NAME_MAX) + 1
        #endif

        var hostNameBuffer = [Int8](repeating: 0, count: maxHostNameLength)
        let error = gethostname(&hostNameBuffer, maxHostNameLength)
        guard error == 0 else { return nil }
        return String(cString: hostNameBuffer)
    }

    #if !os(Linux)

    public static func resolveAddress(fromHost name: String, family: Int32 = AF_INET) -> String? {
        var success: DarwinBoolean = false
        let host = CFHostCreateWithName(nil, name as CFString).takeRetainedValue()
        guard CFHostStartInfoResolution(host, .addresses, nil),
              let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as NSArray?
            else { return nil }
        return self.resolveAddress(from: addresses, family: family)
    }

    public static func resolveAddress(from addresses: NSArray, family: Int32 = AF_INET) -> String? {
        let socketAddresses = addresses.compactMap { ($0 as? NSData)?.bytes.bindMemory(to: sockaddr.self, capacity: 1) }
        guard let socketAddress = socketAddresses.first(where: { $0.pointee.sa_family == family }) else { return nil }
        return self.hostName(from: socketAddress)
    }

    #endif

    private static func hostName(from socketAddress: UnsafePointer<sockaddr>) -> String? {
        var hostName = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(socketAddress, socklen_t(MemoryLayout.size(ofValue: socketAddress)), &hostName, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: hostName)
    }

    public static func resolveAddress(from addresses: [Data], family: Int32 = AF_INET) -> String? {
        guard var socketAddress = addresses.map({ $0.withUnsafeBytes { $0 }})
                .map({ $0.bindMemory(to: sockaddr.self) }).first?
                .first(where: { $0.sa_family == family })
            else { return nil }
        return self.hostName(from: &socketAddress)
    }

    public static func resolveAddress(from host: String, family: Int32 = AF_INET) -> String? {
        guard let address = self.resolveAddresses(from: host)
                .first(where: { $0.family == family })
            else { return nil }
        return address.address
    }

    public static func resolveAddresses(from host: String) -> [(address: String, family: Int32)] {
        var addressInfoDoublePointer: UnsafeMutablePointer<addrinfo>?
        #if os(Linux)
        var hints = addrinfo(ai_flags: 0, ai_family: PF_UNSPEC, ai_socktype: Int32(SOCK_STREAM.rawValue), ai_protocol: 0, ai_addrlen: 0, ai_addr: nil, ai_canonname: nil, ai_next: nil)
        #else
        var hints = addrinfo(ai_flags: 0, ai_family: PF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        #endif
        guard getaddrinfo(host, nil, &hints, &addressInfoDoublePointer) == 0 else { return [] }

        var result: [(address: String, family: Int32)] = []
        let bufferSize = UInt32(max(INET_ADDRSTRLEN, INET6_ADDRSTRLEN))
        let addressStringBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: Int(bufferSize))
        defer { addressStringBuffer.deallocate() }

        while let addressInfoPointer = addressInfoDoublePointer {
            let addressInfo = addressInfoPointer.pointee
            switch addressInfo.ai_family {
                case AF_INET:
                    var socketPointer = addressInfo.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    guard inet_ntop(addressInfo.ai_family, &socketPointer, addressStringBuffer, bufferSize) != nil else { continue }
                case AF_INET6:
                    var socketPointer = addressInfo.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    guard inet_ntop(addressInfo.ai_family, &socketPointer, addressStringBuffer, bufferSize) != nil else { continue }
                default:
                    continue
            }

            result.append((String(cString: addressStringBuffer), addressInfo.ai_family))
            addressInfoDoublePointer = addressInfo.ai_next
        }

        return result
    }
}
