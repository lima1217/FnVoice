import AppKit
import AVFoundation
import Speech

enum Permission: CaseIterable {
    case accessibility, inputMonitoring, microphone, speechRecognition

    var title: String {
        switch self {
        case .accessibility: "辅助功能"
        case .inputMonitoring: "输入监控"
        case .microphone: "麦克风"
        case .speechRecognition: "语音识别"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: "用于拦截 Fn 键并粘贴文字"
        case .inputMonitoring: "用于检测 Fn 键"
        case .microphone: "用于收音"
        case .speechRecognition: "用于转写"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

@MainActor enum Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition: SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    static var missing: [Permission] { Permission.allCases.filter { !isGranted($0) } }

    /// Shows the system prompt where one exists; otherwise (already denied) opens System Settings.
    static func request(_ p: Permission) async {
        switch p {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(p) }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings(p) }
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                openSettings(p)
            }
        case .speechRecognition:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await requestSpeech()
            } else {
                openSettings(p)
            }
        }
    }

    nonisolated static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    static func openSettings(_ p: Permission) {
        NSWorkspace.shared.open(p.settingsURL)
    }
}
