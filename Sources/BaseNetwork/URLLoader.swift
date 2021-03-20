//
//  URLLoader.swift
//
//  Copyright © 2019-2021 Purgatory Design. Licensed under the MIT License.
//

import BaseSwift
import Foundation

public protocol URLLoaderSessionConfigurationDelegate: AnyObject {
	func initializeURLLoaderSession(_ type: URLLoader.SessionType, configuration: URLSessionConfiguration)
}

public final class URLLoader: NSObject {
	public enum SessionType { case `default`, ephemeral, background }
    public typealias TaskStateNotifier = (URLSessionTask, UUID) -> Void

	public static let shared = URLLoader()
	public static let appBackgroundTaskID = "\(URLLoader.identifierPrefix).URLLoaderBackgroundTask"
	public static let queueName = "\(URLLoader.identifierPrefix).URLLoaderQueue"

	public let backgroundSessionID: String

	public lazy var defaultUrlSession: URLSession = { self.createURLSession(.default) }()
	public lazy var ephemeralUrlSession: URLSession = { self.createURLSession(.ephemeral) }()
	public lazy var backgroundUrlSession: URLSession = { self.createURLSession(.background) }()

	/// The operation queue used for all task and delegate interactions.
	///
	public static let operationQueue: OperationQueue = {
		let result = OperationQueue()
		result.name = URLLoader.queueName
		result.maxConcurrentOperationCount = 1
		return result
	}()

    private var taskDelegates: [UUID: WeakDelegate] = [:]   // only to be accessed from URLLoader.operationQueue
    private var taskSubjects: [UUID: WeakSubject] = [:]     // only to be accessed from URLLoader.operationQueue
	private var instantiatedSessions: [SessionType: URLSession] = [:]
	private var backgroundCompletionHandler: (() -> Void)?
    private var taskCompletionNotifier: TaskStateNotifier?
    private weak var configurationDelegate: URLLoaderSessionConfigurationDelegate?
	private weak var fallbackDelegate: URLSessionTaskDelegate?

	/// Initialize the receiver with properties for all URL sessions.
	///
	/// - Parameters:
	///   - configurationDelegate: An optional session configuration delegate (this is held with a strong reference).
	///   - backgroundSessionID: The identifier of the receiver's background session.
	///
	public init(configurationDelegate: URLLoaderSessionConfigurationDelegate? = nil, backgroundSessionID: String? = nil) {
		self.backgroundSessionID = backgroundSessionID ?? URLLoader.defaultBackgroundSessionID
		self.configurationDelegate = configurationDelegate
	}

	/// Returns a specific URL session of the receiver.
	///
	/// - Parameter session: The session to return.
	/// - Returns: The requested URL session.
	///
	public func urlSession(_ session: SessionType) -> URLSession {
		switch session {
			case .default: return self.defaultUrlSession
			case .ephemeral: return self.ephemeralUrlSession
			case .background: return self.backgroundUrlSession
		}
	}

	/// Finish all tasks and invalidate the receiver's URL sessions.
	///
	/// - Note:	Because URLSession retains a strong reference to its delegate until it's invalidated,
	///			the receiver may not be released until this is called.
	///
	public func finishTasksAndInvalidate() {
		self.instantiatedSessions.forEach { $0.value.finishTasksAndInvalidate() }
		self.instantiatedSessions.removeAll()
	}

	/// Cancel all tasks and invalidate the receiver's URL sessions.
	///
	/// - Note:	Because URLSession retains a strong reference to its delegate until it's invalidated,
	///			the receiver may not be released until this is called.
	///
	public func invalidateAndCancel() {
		self.instantiatedSessions.forEach { $0.value.invalidateAndCancel() }
		self.instantiatedSessions.removeAll()
	}

	/// Initialize the receiver's background URL session.
	///
	/// - Note:	This will allow the completion of any background tasks running while we weren't.
	///			When using background tasks, this should generally be called early in the application's lifecycle.
	///
	public func initializeBackgroundURLSession() {
		URLLoader.operationQueue.addOperation {
			_ = self.backgroundUrlSession
		}
	}

	/// Registers a system completion handler for the receiver's background URL session.
	///
	/// - Parameters:
	///   - identifier: The background session identifier the handler is associated with.
	///   - completionHandler: The background session handler to register.
	///
	/// - Note:	This should be called from the application delegate in response to
	///			UIApplicationDelegate.application.handleEventsForBackgroundURLSession.completionHandler.
	///
	public func registerBackgroundURLSessionHandler(_ identifier: String, completionHandler: @escaping () -> Void) {
		if identifier == self.backgroundSessionID {
			self.backgroundCompletionHandler = completionHandler
		}
	}

	/// Registers a task delegate to be called for specific tasks or a fallback delegate for unregistered tasks.
	///
	/// - Parameters:
	///   - delegate: The task delegate to register with the receiver.
	///   - taskID: The ID of the task to register to the delegate for, or `nil` to register a fallback delegate.
	///
	public func registerDelegate(_ delegate: URLSessionTaskDelegate, for taskID: UUID? = nil) {
		URLLoader.operationQueue.addOperation {
			if let taskID = taskID {
                self.taskDelegates[taskID] = WeakDelegate(delegate: delegate)
			} else {
				self.fallbackDelegate = delegate
			}
		}
	}

    /// Registers a task completion notification function to be called when tasks complete.
    ///
    /// - Parameter notifier: the notification function
    ///
    public func onTaskCompletion(_ notifier: @escaping TaskStateNotifier) {
        self.taskCompletionNotifier = notifier
    }

	/// Upload data to the endpoint specified by a request.
	///
	/// - Parameters:
	///   - request: The request which specifies the upload endpoint.
	///   - bodyData: The data to upload.
	///   - session: The URL session to upload with.
	///   - useTemporaryFile: Specifies if the data should be saved in a temporary file and uploaded from there.
	///   - delegate: The optional delegate for the resulting upload task.
	///   - onTaskStart: An optional function called on the operation queue thread just before the upload task is started.
	/// - Returns: The URLLoader task ID (or nil if the temporary file can't be created).
	///
	/// - Note:	If the specified session is background, useTemporaryFile will always be considered true.
	///
	@discardableResult
	public func upload(_ request: URLRequest, from bodyData: Data, session: SessionType = .default, useTemporaryFile: Bool = false, delegate: URLSessionDataDelegate? = nil, onTaskStart: TaskStateNotifier? = nil) -> UUID? {
		let taskID = UUID()
		let task: URLSessionTask
		if useTemporaryFile || session == .background {
			guard let fileURL = try? URLLoader.createTemporaryFile(named: taskID.uuidString, contents: bodyData) else { return nil }
			task = self.urlSession(session).uploadTask(with: request, fromFile: fileURL)
		} else {
			task = self.urlSession(session).uploadTask(with: request, from: bodyData)
		}
		return self.initializeTask(task, taskID: taskID, delegate: delegate, notifier: onTaskStart)
	}

	/// Upload a file to the endpoint specified by a request.
	///
	/// - Parameters:
	///   - request: The request which specifies the upload endpoint.
	///   - fileURL: The file to upload.
	///   - session: The URL session to upload with.
	///   - delegate: The optional delegate for the resulting upload task.
	///   - onTaskStart: An optional function called on the operation queue thread just before the upload task is started.
	/// - Returns: The URLLoader task ID.
	///
	@discardableResult
	public func upload(_ request: URLRequest, fromFile fileURL: URL, session: SessionType = .default, delegate: URLSessionDataDelegate? = nil, onTaskStart: TaskStateNotifier? = nil) -> UUID {
		let task = self.urlSession(session).uploadTask(with: request, fromFile: fileURL)
		return self.initializeTask(task, delegate: delegate, notifier: onTaskStart)
	}

	/// Download data from the endpoint specified by a request to a file.
	///
	/// - Parameters:
	///   - request: The request which specifies the download endpoint.
	///   - session: The URL session to download with.
	///   - delegate: The optional delegate for the resulting download task.
	///   - onTaskStart: An optional function called on the operation queue thread just before the download task is started.
	/// - Returns: The URLLoader task ID.
	///
	@discardableResult
	public func download(_ request: URLRequest, session: SessionType = .default, delegate: URLSessionDownloadDelegate? = nil, onTaskStart: TaskStateNotifier? = nil) -> UUID {
		let task = self.urlSession(session).downloadTask(with: request)
		return self.initializeTask(task, delegate: delegate, notifier: onTaskStart)
	}
}

//	MARK: Private methods and properties

private extension URLLoader {
    
    private struct WeakDelegate {
        weak var delegate: URLSessionTaskDelegate?

        init?(delegate: URLSessionTaskDelegate?) {
            guard let delegate = delegate else { return nil }
            self.delegate = delegate
        }
    }

	private static let identifierPrefix = "\(Bundle.main.bundleIdentifier ?? "Unspecified")"
	private static let defaultBackgroundSessionID = "\(URLLoader.identifierPrefix).URLLoaderBackgroundSession"
	private static let temporaryDirectoryName = "\(URLLoader.identifierPrefix).TemporaryStorage"
	private static let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(URLLoader.temporaryDirectoryName, isDirectory: true)

	/// Create a URLSession from a SessionType identifier.
	///
	/// - Parameter type: The type of session to create.
	/// - Returns: The URLSession created.
	///
	private func createURLSession(_ type: SessionType) -> URLSession {
		let configuration: URLSessionConfiguration
		switch type {
			case .default: configuration = .default
			case .ephemeral: configuration = .ephemeral
			case .background: configuration = URLSessionConfiguration.background(withIdentifier: self.backgroundSessionID)
		}

		self.configurationDelegate?.initializeURLLoaderSession(type, configuration: configuration)

		let result = URLSession(configuration: configuration, delegate: self, delegateQueue: URLLoader.operationQueue)
		self.instantiatedSessions[type] = result
		return result
	}

	/// Initialize and start a URLSession task.
	///
	/// - Parameters:
	///   - task: The task to initialize.
	///   - taskID: The URLLoader task ID.
	///   - delegate: The optional delegate for the task.
	///   - notifier: An optional function called on the operation queue thread just before the task is started.
	///
    @discardableResult
    private func initializeTask(_ task: URLSessionTask, taskID: UUID = UUID(), delegate: URLSessionTaskDelegate?, notifier: TaskStateNotifier?) -> UUID {
		URLLoader.operationQueue.addOperation {
			self.taskDelegates[taskID] = WeakDelegate(delegate: delegate)
			task.taskDescription = taskID.uuidString
			notifier?(task, taskID)
			task.resume()
		}

		return taskID
	}

    /// Get the delegate for a specific task (if any).
    ///
    /// - Parameters:
    ///   - task: The task with the delegate.
    ///   - remove: Specifies if the delegate should be unregistered from the task.
    /// - Returns: The task delegate (or nil).
    ///
    /// - Note:    This should only be called on the URLLoader.operationQueue thread.
    ///
    private func delegate(for task: URLSessionTask, remove: Bool = false) -> URLSessionTaskDelegate? {
        guard let taskID = task.urlLoaderTaskID,
              let delegateContainer = self.taskDelegates[taskID]
            else { return self.fallbackDelegate }
        if remove { self.taskDelegates.removeValue(forKey: taskID) }
        return delegateContainer.delegate ?? self.fallbackDelegate
    }

	/// Create a temporary file for use during data uploads.
	///
	/// - Parameters:
	///   - name: The file name.
	///   - data: The data to put in the file.
	/// - Returns: The URL of the new temporary file.
	/// - Throws: Any error encountered when creating or saving to the file.
	///
	private static func createTemporaryFile(named name: String, contents: Data) throws -> URL {
		let fileURL = self.temporaryDirectory.appendingPathComponent(name, isDirectory: false)
		try FileManager.default.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
		try contents.write(to: fileURL)
		return fileURL
	}

	/// Delete a temporary file.
	///
	/// - Parameter name: The file name.
	/// - Throws: Any error encountered when deleting the file.
	///
	private static func deleteTemporaryFile(named name: String) throws {
		let fileURL = self.temporaryDirectory.appendingPathComponent(name, isDirectory: false)
		try FileManager.default.removeItem(at: fileURL)
	}
}

//	MARK: Delegate implementations

extension URLLoader: URLSessionTaskDelegate {

	public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		let backgroundTask = BackgroundTask(name: URLLoader.appBackgroundTaskID)
		defer { backgroundTask.end() }

		if let taskID = task.urlLoaderTaskID {
			try? URLLoader.deleteTemporaryFile(named: taskID.uuidString)
            self.taskCompletionNotifier?(task, taskID)
		}

		if let delegate = self.delegate(for: task, remove: true), delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:))) {
            delegate.urlSession?(session, task: task, didCompleteWithError: error)
        }

        if let subject = self.subject(for: task, remove: true) {
            if let error = error {
                subject.send(completion: .failure(error))
            } else {
                subject.send(completion: .finished)
            }
        }
    }

	public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		DispatchQueue.main.async {
			self.backgroundCompletionHandler?()
			self.backgroundCompletionHandler = nil
		}
	}
}

extension URLLoader: URLSessionDownloadDelegate {

	public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let subject = self.subject(for: downloadTask)
        let delegate = self.delegate(for: downloadTask) as? URLSessionDownloadDelegate
        guard subject != nil || delegate != nil else { return }
		let backgroundTask = BackgroundTask(name: URLLoader.appBackgroundTaskID)
        defer { backgroundTask.end() }
        subject?.send(location)
		delegate?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
	}

	public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let delegate = self.delegate(for: downloadTask) as? URLSessionDownloadDelegate,
              delegate.responds(to: #selector(URLSessionDownloadDelegate.urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)))
			else { return }
		let backgroundTask = BackgroundTask(name: URLLoader.appBackgroundTaskID)
        defer { backgroundTask.end() }
		delegate.urlSession?(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
	}

	public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
		guard let delegate = self.delegate(for: downloadTask) as? URLSessionDownloadDelegate,
              delegate.responds(to: #selector(URLSessionDownloadDelegate.urlSession(_:downloadTask:didResumeAtOffset:expectedTotalBytes:)))
			else { return }
		let backgroundTask = BackgroundTask(name: URLLoader.appBackgroundTaskID)
        defer { backgroundTask.end() }
		delegate.urlSession?(session, downloadTask: downloadTask, didResumeAtOffset: fileOffset, expectedTotalBytes: expectedTotalBytes)
	}
}

extension URLLoader: URLSessionDataDelegate {

	public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
		guard let delegate = self.delegate(for: dataTask) as? URLSessionDataDelegate,
              delegate.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:completionHandler:)))
			else { completionHandler(.allow); return }
		let backgroundTask = BackgroundTask(name: URLLoader.appBackgroundTaskID)
		delegate.urlSession?(session, dataTask: dataTask, didReceive: response) { responseDisposition in
			completionHandler(responseDisposition)
			backgroundTask.end()
		}
	}

	public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		guard let delegate = self.delegate(for: dataTask) as? URLSessionDataDelegate,
              delegate.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:)))
			else { return }
		let backgroundTask = BackgroundTask(name: URLLoader.appBackgroundTaskID)
        defer { backgroundTask.end() }
		delegate.urlSession?(session, dataTask: dataTask, didReceive: data)
	}
}

//	MARK: Utility extensions

public extension URLSessionTask {

	/// Gets the URLLoader task ID associated with the receiver (if any).
	///
	var urlLoaderTaskID: UUID? {
		guard let taskDescription = self.taskDescription else { return nil }
		return UUID(uuidString: taskDescription)
	}
}

//    MARK: Combine extensions

#if canImport(Combine)

import Combine

extension URLLoader {
    public typealias DownloadPublisher = Publishers.CompactMap<CurrentValueSubject<URL?, Error>, URL>   // Output: URL, Failure: Error
    private typealias DownloadSubject = CurrentValueSubject<URL?, Error>

    private struct WeakSubject {
        weak var subject: DownloadSubject?
    }

    /// Create a publisher for an existing file download task.
    ///
    /// - Parameter taskID: The ID of the download task to create a publisher for.
    /// - Returns: A publisher of the downloaded file URL.
    ///
    /// - Note: This replaces any existing publisher for the specified task, however it is useful to create publishers for background downloads left running after app termination.
    ///
    public func downloadPublisher(for taskID: UUID) -> DownloadPublisher {
        let subject = DownloadSubject(nil)
        URLLoader.operationQueue.addOperation { self.taskSubjects[taskID] = WeakSubject(subject: subject) }
        return subject.compactMap { $0 }
    }

    /// Download data from the endpoint specified by a request to a file.
    ///
    /// - Parameters:
    ///   - request: The request which specifies the download endpoint.
    ///   - session: The URL session to download with.
    ///   - onTaskStart: An optional function called on the operation queue thread just before the download task is started.
    /// - Returns: A publisher of the downloaded file URL.
    ///
    public func downloadPublisher(_ request: URLRequest, session: SessionType = .default, onTaskStart: TaskStateNotifier? = nil) -> DownloadPublisher {
        let task = self.urlSession(session).downloadTask(with: request)
        let subject = DownloadSubject(nil)
        self.initializeTask(task, delegate: nil) { task, taskID in
            self.taskSubjects[taskID] = WeakSubject(subject: subject)
            onTaskStart?(task, taskID)
        }

        return subject.compactMap { $0 }
    }

    /// Get the subject for a specific task (if any).
    ///
    /// - Parameters:
    ///   - task: The task with the subject.
    ///   - remove: Specifies if the subject should be unregistered from the task.
    /// - Returns: The task subject (or nil).
    ///
    /// - Note:    This should only be called on the URLLoader.operationQueue thread.
    ///
    private func subject(for task: URLSessionTask, remove: Bool = false) -> DownloadSubject? {
        guard let taskID = task.urlLoaderTaskID else { return nil }
        defer { if remove { self.taskSubjects.removeValue(forKey: taskID) }}
        return self.taskSubjects[taskID]?.subject
    }
}

#else

/// Stubs to allow Combine features to compile when it isn't available (e.g., Linux).
///
extension URLLoader {

    private struct WeakSubject {

        fileprivate enum Completion {
            case failure(Error)
            case finished
        }

        fileprivate func send(_ url: URL) {}

        fileprivate func send(completion: Completion) {}
    }

    private func subject(for task: URLSessionTask, remove: Bool = false) -> WeakSubject? { nil }
}

#endif
