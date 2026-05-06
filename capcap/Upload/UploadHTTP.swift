import Foundation

/// URLSession wrapper that surfaces upload progress for a single request.
final class UploadHTTPClient: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private var progress: ((Double) -> Void)?
    private var completion: ((Result<(Data, HTTPURLResponse), Error>) -> Void)?
    private var receivedData = Data()
    private var session: URLSession!
    private var task: URLSessionTask?

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func upload(
        request: URLRequest,
        body: Data,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void
    ) {
        self.progress = progress
        self.completion = completion
        receivedData = Data()
        task = session.uploadTask(with: request, from: body)
        task?.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let pct = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let cb = progress
        DispatchQueue.main.async { cb?(min(max(pct, 0), 1)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cb = completion
        let data = receivedData
        let response = task.response as? HTTPURLResponse
        DispatchQueue.main.async { [weak self] in
            defer { self?.session.finishTasksAndInvalidate() }
            if let error {
                cb?(.failure(UploadError.network(error.localizedDescription)))
                return
            }
            guard let response else {
                cb?(.failure(UploadError.unexpectedResponse("missing response")))
                return
            }
            cb?(.success((data, response)))
        }
    }
}
