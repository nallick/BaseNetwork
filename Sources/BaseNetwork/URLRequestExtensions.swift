//
//  URLRequestExtensions.swift
//
//  Copyright © 2021 Purgatory Design. Licensed under the MIT License.
//

import Foundation

extension URLRequest {

    public enum HttpMethod: String {
        case get = "GET"
        case put = "PUT"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public var method: HttpMethod? {
        get { httpMethod.flatMap { HttpMethod(rawValue: $0) } }
        set { httpMethod = newValue?.rawValue }
    }
}
