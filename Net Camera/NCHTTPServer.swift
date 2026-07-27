import Foundation
import Hummingbird

// MARK: - NCHTTPServer

/// The embedded web server: the netcam half of Net Camera.
///
/// It knows nothing of the application. It is handed nothing and asks for
/// nothing beyond its own bundle resource, and it reports its one interesting
/// outcome — whether the listener came up — through a callback. The picture
/// reaches it the same way the picture reaches the window: as a sink on the
/// frame distributor, registered by whoever owns both.
///
/// The listener runs on Swift concurrency's own threads, never the main one, so
/// starting it cannot delay the app appearing and a slow or wedged client
/// cannot freeze the interface.
final class NCHTTPServer {

    // MARK: - Configuration

    /// The port the netcam answers on. Hard-coded on purpose: there is no
    /// network-configuration UI, so there is no second place this number could
    /// come from and disagree with.
    static let port: Int = 50128

    /// Every interface, not just loopback. The whole point of the server is
    /// that another machine can reach it; binding `127.0.0.1` would serve only
    /// the Mac that does not need serving. Nothing here knows or cares by which
    /// route a client arrives — LAN, VPN or otherwise.
    static let host: String = "0.0.0.0"

    /// The static page, by bundle resource name.
    private static let pageResource: String = "index"
    private static let pageExtension: String = "html"

    // MARK: - Failure

    /// Why the server is not running.
    ///
    /// A server that failed to start and said nothing would present later as a
    /// broken stream, and the search would begin in the wrong half of the app.
    /// Every way of not starting therefore ends up here, with something a user
    /// can act on.
    enum StartFailure: Error {
        /// The static page is not in the bundle, so there is nothing to serve.
        case pageMissing
        /// The listener could not be established — the usual cause by far being
        /// another process already holding the port.
        case listenerFailed(String)

        /// What to tell the user.
        var message: String {
            switch self {
            case .pageMissing:
                return """
                    Net Camera's web page is missing from the application bundle, \
                    so the built-in web server did not start. The camera window \
                    is unaffected.
                    """
            case .listenerFailed(let reason):
                return """
                    Net Camera could not listen on port \(NCHTTPServer.port), so \
                    it cannot be viewed from another machine. Another program is \
                    most likely already using that port. The camera window is \
                    unaffected.

                    \(reason)
                    """
            }
        }
    }

    // MARK: - Properties

    /// The task the server runs in. Held so the server can be stopped; nil
    /// while the server is not running.
    private var runTask: Task<Void, Never>?

    /// Signalled when the run task has finished, so `stop()` can wait for the
    /// listener to actually let go rather than assume it has.
    private let finished: DispatchSemaphore = DispatchSemaphore(value: 0)

    // MARK: - Lifecycle

    /// Brings the listener up, and returns immediately.
    ///
    /// Launch is not held up by the network: the socket is bound on the task's
    /// own thread, and the outcome arrives at `onFailure` afterwards if it was
    /// a bad one. Success is silent apart from the log line naming the address
    /// actually bound, which is the evidence that the server is reachable
    /// rather than merely constructed.
    ///
    /// - Parameters:
    ///   - stream: Where the picture comes from. The server registers and
    ///     unregisters clients with it and knows nothing else about it — the
    ///     sink's own place in the frame pipeline is somebody else's business,
    ///     as it is for the window.
    ///   - onFailure: Called on the main thread, at most once, when the
    ///     server is not going to serve anything.
    func start(
        streaming stream: NCMJPEGSink,
        onFailure: @escaping @Sendable (StartFailure) -> Void
    ) {
        guard runTask == nil else { return }

        guard
            let pageURL: URL = Bundle.main.url(
                forResource: Self.pageResource, withExtension: Self.pageExtension),
            let pageData: Data = try? Data(contentsOf: pageURL)
        else {
            NSLog("Web server not started: %@.%@ is missing from the bundle",
                  Self.pageResource, Self.pageExtension)
            Self.report(.pageMissing, to: onFailure)
            return
        }

        let page: ByteBuffer = ByteBuffer(bytes: pageData)
        let router: Router = Router()

        // The page a browser lands on. Its <img> points at the stream, which is
        // a separate consumer of the same frames the window draws.
        router.get("/") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: ResponseBody(byteBuffer: page))
        }

        // The picture itself: a response that never ends, one JPEG per part.
        //
        // The client is registered before the body starts and unregistered
        // however the body ends — normally, by error, or by the connection
        // being cut — because a client left registered is a phantom that keeps
        // the encoder running for nobody.
        router.get("/stream") { _, _ -> Response in
            let client: NCMJPEGClient = stream.open()
            return Response(
                status: .ok,
                headers: [
                    .contentType: NCMJPEGFraming.contentType,
                    // Live pictures are not cacheable in any useful sense, and
                    // an intermediary that held on to one would be showing a
                    // photograph of the past for ever.
                    .cacheControl: "no-store, no-cache, must-revalidate",
                ],
                body: ResponseBody { writer in
                    defer { stream.close(client) }
                    do {
                        for await part: Data in client.parts {
                            try await writer.write(ByteBuffer(bytes: part))
                        }
                        // Reached when the sink ends the client's stream rather
                        // than the client leaving: the body is closed off
                        // properly instead of merely stopping.
                        try await writer.write(ByteBuffer(bytes: NCMJPEGFraming.terminator))
                        try await writer.finish(nil)
                    } catch {
                        // A browser closing its tab, or a network that went
                        // away mid-frame, is how a live stream ordinarily ends.
                        // It is traced rather than thrown, because it is not a
                        // fault of the server's.
                        NSLog("Stream client left mid-frame: %@", String(describing: error))
                    }
                })
        }

        let application = Application(
            router: router,
            configuration: ApplicationConfiguration(
                address: .hostname(Self.host, port: Self.port),
                serverName: "Net Camera"),
            onServerRunning: { channel in
                NSLog("Web server listening on %@ port %d",
                      Self.host, channel.localAddress?.port ?? Self.port)
            })

        // Detached, because the server's lifetime is the application's and not
        // that of whatever context happened to start it, and because nothing it
        // does belongs on the main thread.
        //
        // No signal handlers are installed. Hummingbird's default would claim
        // SIGINT and SIGTERM for the server, and a GUI application that stops
        // answering `kill` because its web server took the signals over is a
        // surprise nobody asked for.
        runTask = Task.detached { [finished] in
            defer { finished.signal() }
            do {
                try await application.runService(gracefulShutdownSignals: [])
                NSLog("Web server stopped")
            } catch is CancellationError {
                NSLog("Web server stopped")
            } catch {
                NSLog("Web server failed to listen on %@ port %d: %@",
                      Self.host, Self.port, String(describing: error))
                Self.report(.listenerFailed(String(describing: error)), to: onFailure)
            }
        }
    }

    /// Takes the listener down and waits, briefly, for it to let go.
    ///
    /// The wait is bounded because quitting must not be able to hang: a server
    /// that will not stop loses its socket to the process exiting a moment
    /// later either way, and the log says which of the two happened.
    func stop() {
        guard let task: Task<Void, Never> = runTask else { return }
        runTask = nil
        task.cancel()
        if finished.wait(timeout: .now() + 2.0) == .timedOut {
            NSLog("Web server did not stop within 2s; quitting without it")
        }
    }

    // MARK: - Reporting

    /// User-facing failures belong to the main thread, whichever thread noticed
    /// them. Static, because the listener's own failure is noticed inside the
    /// run task, which has no business holding the server alive to report it.
    private static func report(
        _ failure: StartFailure, to onFailure: @escaping @Sendable (StartFailure) -> Void
    ) {
        DispatchQueue.main.async { onFailure(failure) }
    }
}
