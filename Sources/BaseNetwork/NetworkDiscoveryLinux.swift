//
//  NetworkDiscovery.swift
//
//  Copyright © 2019 Purgatory Design. Licensed under the MIT License.
//

#if os(Linux)

import dns_sd
import Foundation

public final class NetworkDiscoveryLinux {

    public enum LocateError: Error {
        case didNotSearch([String: NSNumber])
        case timeout
    }

    public enum ResolveError: Error {
        case didNotResolve([String: NSNumber])
        case hostDidNotResolve
        case timeout
    }

    public enum PublishError: Error {
        case didNotPublish([String: NSNumber])
        case invalidTxtRecord(Error)
    }

    public struct ResolvedService {
        public let address: String
        public let port: Int32
        public let txtRecord: [String: Data]
    }

    public typealias LocateCompletion = (Result<Set<DNSService.LocatedService>, LocateError>) -> Void
    public typealias ResolveCompletion = (Result<ResolvedService, ResolveError>) -> Void
    public typealias PublishCompletion = (Result<DNSService.RegisteredService, PublishError>) -> Void

    public private(set) var locatedServices: Set<DNSService.LocatedService> = []

    public static let errorCodeKey = "errorCodeKey"
    public static let errorDomainKey = "errorDomainKey"

    private var timeoutTimer: Timer?
    private var maximumServiceCount = 0
    private var browseService: DNSService?
    private var resolveService: DNSService?
    private var publishService: DNSService?

    deinit {
        self.timeoutTimer?.invalidate()
        self.browseService?.stop()
        self.resolveService?.stop()
        self.publishService?.stop()
    }

    public func locateServices(ofType type: String = "_http._tcp", inDomain domain: String = "", maximumServiceCount: Int = 0, timeout: TimeInterval = 10.0, completion: @escaping LocateCompletion) {
        self.browseService?.stop()
        self.browseService = nil
        self.locatedServices.removeAll()
        self.maximumServiceCount = maximumServiceCount

        let result = DNSService.browseServices(ofType: type, inDomain: domain,
           errorCallback: { error in
            completion(Result.failure(.didNotSearch([NetworkDiscoveryLinux.errorCodeKey: error.rawValue as NSNumber])))
           },
           serviceCallback: { service, locatedService in
            let moreComing = locatedService.flags.contains(.moreComing)
            self.locatedServices.insert(locatedService)
            if !moreComing || (self.maximumServiceCount > 0 && self.locatedServices.count >= self.maximumServiceCount) {
                self.timeoutTimer?.invalidate()
                self.timeoutTimer = nil
                self.browseService = nil
                service.stop()
                completion(Result.success(self.locatedServices))
            }
           })

        switch result {
            case .success(let service):
                self.browseService = service
            case .failure(let error):
                completion(Result.failure(.didNotSearch([NetworkDiscoveryLinux.errorCodeKey: error.rawValue as NSNumber])))
                return
        }

        self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            self.browseService?.stop()
            self.browseService = nil
            completion(Result.failure(LocateError.timeout))
            self.timeoutTimer = nil
        }
    }

    public func resolve(service: DNSService.LocatedService, networkFamily: Int32 = AF_INET, timeout: TimeInterval = 10.0, completion: @escaping ResolveCompletion) {
        self.resolveService?.stop()
        self.resolveService = nil

        let result = DNSService.resolveService(service,
           errorCallback: { error in
            completion(Result.failure(.didNotResolve([NetworkDiscoveryLinux.errorCodeKey: error.rawValue as NSNumber])))
           },
           serviceCallback: { service, resolvedService in
            self.timeoutTimer?.invalidate()
            self.timeoutTimer = nil
            self.resolveService = nil
            service.stop()
            guard let address = Network.resolveAddress(from: resolvedService.hostTarget, family: networkFamily) else { completion(Result.failure(.hostDidNotResolve)); return }
            completion(Result.success(ResolvedService(address: address, port: Int32(resolvedService.port), txtRecord: resolvedService.txtRecord.dictionary)))
           })

        switch result {
            case .success(let service):
                self.resolveService = service
            case .failure(let error):
                completion(Result.failure(.didNotResolve([NetworkDiscoveryLinux.errorCodeKey: error.rawValue as NSNumber])))
        }

        self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            self.resolveService?.stop()
            completion(Result.failure(ResolveError.timeout))
            self.timeoutTimer = nil
        }
    }

    // valid options include: .noAutoRename
    //
    public func publishService(named name: String? = nil, ofType type: String, inDomain domain: String? = nil, port: Int32, txtRecord: [String: Data] = [:], options: DNSService.Flags = [], completion: @escaping PublishCompletion) {
        self.publishService?.stop()
        self.publishService = nil

        var record: TXTRecord?
        if !txtRecord.isEmpty {
            do {
                try record = TXTRecord(txtRecord)
            } catch {
                completion(Result.failure(.invalidTxtRecord(error)))
                return
            }
        }

        let result = DNSService.registerService(named: name, ofType: type, inDomain: domain, port: UInt16(port), txtRecord: record, flags: options,
            errorCallback: { error in
                completion(Result.failure(.didNotPublish([NetworkDiscoveryLinux.errorCodeKey: error.rawValue as NSNumber])))
            },
            serviceCallback: { service, registeredService in
                completion(Result.success(registeredService))
            })

        switch result {
            case .success(let service):
                self.publishService = service
            case .failure(let error):
                completion(Result.failure(.didNotPublish([NetworkDiscoveryLinux.errorCodeKey: error.rawValue as NSNumber])))
        }
    }
}

#endif
