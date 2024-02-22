//
//  NetworkDiscovery.swift
//
//  Copyright © 2019-2024 Purgatory Design. Licensed under the MIT License.
//

import Foundation

#if !os(Linux)

public final class NetworkDiscovery: NSObject {

    public enum LocateError: Error {
        case didNotSearch([String: NSNumber])
        case timeout
    }

    public enum ResolveError: Error {
        case didNotResolve([String: NSNumber])
    }

    public enum PublishError: Error {
        case didNotPublish([String: NSNumber])
        case invalidTxtRecord
    }

    public struct ResolvedService {
        public let address: String
        public let port: Int32
        public let txtRecord: [String: Data]
    }

    public typealias LocateCompletion = (Result<Set<NetService>, LocateError>) -> Void
    public typealias ResolveCompletion = (Result<ResolvedService, ResolveError>) -> Void
    public typealias PublishCompletion = (Result<NetService, PublishError>) -> Void

    public private(set) var locatedServices: Set<NetService> = []

    public static let errorCodeKey = NetService.errorCode
    public static let errorDomainKey = NetService.errorDomain

    private var serviceBrowser: NetServiceBrowser?
    private var resolveService: NetService?
    private var publishService: NetService?
    private var locateCompletion: LocateCompletion?
    private var resolveCompletion: ResolveCompletion?
    private var publishCompletion: PublishCompletion?
    private var resolveNetworkFamily: Int32 = AF_INET
    private var maximumServiceCount = 0
    private var locateTimer: Timer?

    deinit {
        self.locateTimer?.invalidate()
        self.serviceBrowser?.delegate = nil
        self.serviceBrowser?.stop()
        self.resolveService?.delegate = nil
        self.resolveService?.stop()
        self.publishService?.delegate = nil
        self.publishService?.stop()
    }

    public func locateServices(ofType type: String = "_http._tcp", inDomain domain: String = "", maximumServiceCount: Int = 0, timeout: TimeInterval = 10.0, completion: @escaping LocateCompletion) {
        self.serviceBrowser?.stop()
        self.locatedServices.removeAll()
        self.locateCompletion = completion
        self.maximumServiceCount = maximumServiceCount

        if self.serviceBrowser == nil {
            let serviceBrowser = NetServiceBrowser()
            serviceBrowser.delegate = self
            self.serviceBrowser = serviceBrowser
        }

        self.serviceBrowser?.searchForServices(ofType: type, inDomain: domain)

        self.locateTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            self.serviceBrowser?.stop()
            self.locateCompletion?(Result.failure(LocateError.timeout))
            self.locateCompletion = nil
            self.locateTimer = nil
        }
    }

    public func resolve(service: NetService, networkFamily: Int32 = AF_INET, timeout: TimeInterval = 10.0, completion: @escaping ResolveCompletion) {
        self.resolveService = service
        self.resolveNetworkFamily = networkFamily
        self.resolveCompletion = completion
        service.delegate = self
        service.resolve(withTimeout: timeout)
    }

    public func publishService(named name: String = "", ofType type: String, inDomain domain: String = "", port: Int32, txtRecord: [String: Data] = [:], options: NetService.Options = [], completion: @escaping PublishCompletion) {
        let service = NetService(domain: domain, type: type, name: name, port: port)
        if !txtRecord.isEmpty {
            let txtRecordData = NetService.data(fromTXTRecord: txtRecord)
            guard service.setTXTRecord(txtRecordData) else { completion(Result.failure(PublishError.invalidTxtRecord)); return }
        }
        self.publishService = service
        self.publishCompletion = completion
        service.delegate = self
        service.publish(options: options)
    }
}

extension NetworkDiscovery: NetServiceDelegate {

    public func netServiceDidPublish(_ service: NetService) {
        service.delegate = nil
        self.publishService = nil
        self.publishCompletion?(Result.success(service))
        self.publishCompletion = nil
    }

    public func netService(_ service: NetService, didNotPublish errorDictionary: [String: NSNumber]) {
        service.delegate = nil
        self.publishService = nil
        self.publishCompletion?(Result.failure(PublishError.didNotPublish(errorDictionary)))
        self.publishCompletion = nil
    }

    public func netServiceDidResolveAddress(_ service: NetService) {
        let resolvedAddress: String
        if let addresses = service.addresses, let address = Network.resolveAddress(from: addresses, family: self.resolveNetworkFamily) {
            resolvedAddress = address
        } else {
            resolvedAddress = ""
        }

        let serviceDictionary: [String: Data]
        if let data = service.txtRecordData() {
            serviceDictionary = NetService.dictionary(fromTXTRecord: data)
        } else {
            serviceDictionary = [:]
        }

        service.delegate = nil
        self.resolveService = nil
        self.resolveCompletion?(.success(ResolvedService(address: resolvedAddress, port: Int32(service.port), txtRecord: serviceDictionary)))
        self.resolveCompletion = nil
    }

    public func netService(_ service: NetService, didNotResolve errorDictionary: [String: NSNumber]) {
        service.delegate = nil
        self.resolveService = nil
        self.resolveCompletion?(Result.failure(ResolveError.didNotResolve(errorDictionary)))
        self.resolveCompletion = nil
    }

    public func netServiceDidStop(_ service: NetService) {
        guard service == self.resolveService else { return }
        service.delegate = nil
        self.resolveService = nil
        self.resolveCompletion?(Result.failure(ResolveError.didNotResolve([:])))
        self.resolveCompletion = nil
    }
}

extension NetworkDiscovery: NetServiceBrowserDelegate {

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        self.locatedServices.insert(service)
        if !moreComing || (self.maximumServiceCount > 0 && self.locatedServices.count >= self.maximumServiceCount) {
            browser.stop()
            self.locateTimer?.invalidate()
            self.locateCompletion?(Result.success(self.locatedServices))
            self.locateCompletion = nil
            self.locateTimer = nil
        }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        self.locatedServices.remove(service)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDictionary: [String: NSNumber]) {
        browser.stop()
        self.locateTimer?.invalidate()
        self.locateCompletion?(Result.failure(LocateError.didNotSearch(errorDictionary)))
        self.locateCompletion = nil
        self.locateTimer = nil
    }
}

@available(swift 5.5)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, visionOS 1.0, *)
extension NetworkDiscovery {

    @MainActor
    public func locateServices(ofType type: String = "_http._tcp", inDomain domain: String = "", maximumServiceCount: Int = 0, timeout: TimeInterval = 10.0) async throws -> Set<NetService> {
        return try await withCheckedThrowingContinuation { continuation in
            self.locateServices(ofType: type, inDomain: domain, maximumServiceCount: maximumServiceCount, timeout: timeout) { locateResult in
                if let error = locateResult.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: locateResult.value ?? [])
                }
            }
        }
    }

    @MainActor
    public func resolve(service: NetService, networkFamily: Int32 = AF_INET, timeout: TimeInterval = 10.0) async throws -> ResolvedService {
        return try await withCheckedThrowingContinuation { continuation in
            self.resolve(service: service, networkFamily: networkFamily, timeout: timeout) { resolveResult in
                if let value = resolveResult.value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: resolveResult.error ?? .didNotResolve([:]))
                }
            }
        }
    }

    @MainActor
    public func publishService(named name: String = "", ofType type: String, inDomain domain: String = "", port: Int32, txtRecord: [String: Data] = [:], options: NetService.Options = []) async throws -> NetService {
        return try await withCheckedThrowingContinuation { continuation in
            self.publishService(named: name, ofType: type, inDomain: domain, port: port, txtRecord: txtRecord, options: options) { publishResult in
                if let value = publishResult.value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: publishResult.error ?? .didNotPublish([:]))
                }
            }
        }
    }
}

#endif
