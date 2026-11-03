import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--eval") {
            Task { @MainActor in exit(await EvalRunner.run(arguments: args)) }
        } else if args.contains("--selftest-inject") {
            Task { @MainActor in exit(await InjectSelfTest.run(arguments: args)) }
        } else {
            controller.start()
        }
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
