import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created only for a normal launch: its init reads the API key from the Keychain, and with a
    /// self-signed build every rebuild is a new app to the Keychain, so each read in a test mode
    /// (probe, e2e, smoke) would ask for the login password.
    private var controller: AppController?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--eval-live") {
            Task { @MainActor in exit(await LiveEvalRunner.run(arguments: args)) }
        } else if args.contains("--eval") {
            Task { @MainActor in exit(await EvalRunner.run(arguments: args)) }
        } else if args.contains("--latency-bench") {
            Task { @MainActor in
                guard #available(macOS 26.0, *) else { exit(64) }
                exit(await LatencyBench.run(arguments: args))
            }
        } else if args.contains("--ax-probe") {
            Task { @MainActor in exit(await AXProbe.run(arguments: args)) }
        } else if args.contains("--selftest-inject") {
            Task { @MainActor in exit(await InjectSelfTest.run(arguments: args)) }
        } else {
            let controller = AppController()
            self.controller = controller
            controller.start()
            quitOnSIGTERM()
            if args.contains("--first-press") {
                let after = argumentValue("--after", in: args).flatMap(Int.init) ?? 5
                controller.firstPressBench(after: .seconds(after))
            }
        }
    }

    /// `pkill` (make install / run / coldstart) sends SIGTERM, which by default kills the process
    /// without `applicationWillTerminate`, losing the open edit watch's history line and whatever
    /// it would have learned. Route it through a normal quit instead.
    private func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        sigterm = source
    }
}

func argumentValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
