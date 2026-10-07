import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: - Settings

let defaultHotkey = "cmd+shift+9"
let hotkeyDefaultsKey = "hotkey"
let bubbleDiameter: CGFloat = 220
let bubbleMargin: CGFloat = 24
let framesPerSecond: Int32 = 30
let videoBitrate = 8_000_000
let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Movies/Recordings")

private let hotkeyKeyCodes: [String: Int] = [
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
    "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
    "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    "z": kVK_ANSI_Z, "space": kVK_Space,
]

private let hotkeyModifierFlags: [String: Int] = [
    "cmd": cmdKey, "command": cmdKey, "shift": shiftKey,
    "option": optionKey, "opt": optionKey, "alt": optionKey, "ctrl": controlKey, "control": controlKey,
]

/// Parses text like "cmd+shift+9" into a Carbon key code and modifier mask. Needs at least one modifier.
func parseHotkey(_ text: String) -> (keyCode: UInt32, modifiers: UInt32)? {
    let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let key = parts.last, let keyCode = hotkeyKeyCodes[key] else { return nil }
    var modifiers = 0
    for part in parts.dropLast() {
        guard let flag = hotkeyModifierFlags[part] else { return nil }
        modifiers |= flag
    }
    return modifiers == 0 ? nil : (UInt32(keyCode), UInt32(modifiers))
}

func mainDisplayID() -> CGDirectDisplayID {
    let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return number?.uint32Value ?? CGMainDisplayID()
}

// MARK: - Camera bubble

final class CameraBubble {
    private let session = AVCaptureSession()
    private var panel: NSPanel?
    private let sessionQueue = DispatchQueue(label: "camera-session")

    func show() throws {
        if panel != nil { return }
        guard let device = AVCaptureDevice.default(for: .video) else { throw RecorderError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        if session.inputs.isEmpty, session.canAddInput(input) { session.addInput(input) }

        let frame = bubbleFrame()
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = frame.width / 2
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel

        sessionQueue.async { self.session.startRunning() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        sessionQueue.async { self.session.stopRunning() }
    }

    private func bubbleFrame() -> NSRect {
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSRect(x: area.minX + bubbleMargin,
                      y: area.maxY - bubbleMargin - bubbleDiameter,
                      width: bubbleDiameter, height: bubbleDiameter)
    }
}

// MARK: - Recorder

enum RecorderError: LocalizedError {
    case noDisplay, noCamera, noMicrophone, writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to record."
        case .noCamera: return "No camera found."
        case .noMicrophone: return "No microphone found."
        case .writerFailed(let message): return "Could not write the video: \(message)"
        }
    }
}

final class Recorder: NSObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "recorder")
    private let micSession = AVCaptureSession()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var lastVideoTime = CMTime.zero
    private var micEnabled = true
    private(set) var outputURL: URL?

    func start(excludingWindowIDs: [CGWindowID], micEnabled: Bool) async throws {
        self.micEnabled = micEnabled
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = mainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
        else { throw RecorderError.noDisplay }

        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(filter.contentRect.width * scale)
        let height = Int(filter.contentRect.height * scale)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6

        let micOutput = try configureMicrophone()
        try configureWriter(width: width, height: height, micOutput: micOutput)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        micSession.startRunning()
    }

    func setMicEnabled(_ enabled: Bool) {
        queue.async { self.micEnabled = enabled }
    }

    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        micSession.stopRunning()
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let writer = self.writer, self.sessionStart != nil else {
                    self.writer?.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.endSession(atSourceTime: self.lastVideoTime)
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? self.outputURL : nil)
                }
            }
        }
    }

    private func configureMicrophone() throws -> AVCaptureAudioDataOutput {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError.noMicrophone }
        let input = try AVCaptureDeviceInput(device: device)
        if micSession.inputs.isEmpty, micSession.canAddInput(input) { micSession.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        if micSession.canAddOutput(output) { micSession.addOutput(output) }
        return output
    }

    private func configureWriter(width: Int, height: Int, micOutput: AVCaptureAudioDataOutput) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = outputDirectory.appendingPathComponent("Recording \(formatter.string(from: Date())).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitrate],
        ])
        video.expectsMediaDataInRealTime = true

        let audioSettings = micOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true

        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.outputURL = url
        self.sessionStart = nil
    }

    // Screen frames
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let writer, let videoInput else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStart == nil {
            writer.startSession(atSourceTime: time)
            sessionStart = time
        }
        if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
            lastVideoTime = time
        }
    }

    // Microphone samples. Muting drops them, which leaves silence in the audio track.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard micEnabled, let start = sessionStart, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        audioInput.append(sampleBuffer)
    }
}

// MARK: - Control panel

final class ControlPanel {
    let panel: NSPanel
    private let recordButton = NSButton()
    private let micButton = NSButton()
    private let cameraButton = NSButton()

    var onRecordTapped: (() -> Void)?
    var onMicTapped: (() -> Void)?
    var onCameraTapped: (() -> Void)?

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }
    var isVisible: Bool { panel.isVisible }

    init() {
        let size = NSSize(width: 460, height: 64)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        for (button, action) in [(recordButton, #selector(recordTapped)),
                                 (micButton, #selector(micTapped)),
                                 (cameraButton, #selector(cameraTapped))] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.imagePosition = .imageLeading
            button.target = self
            button.action = action
        }

        let stack = NSStackView(views: [recordButton, micButton, cameraButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
    }

    func update(isRecording: Bool, micOn: Bool, cameraOn: Bool) {
        set(recordButton, title: isRecording ? "Stop" : "Record",
            symbol: isRecording ? "stop.circle.fill" : "record.circle.fill", tint: .systemRed)
        set(micButton, title: micOn ? "Mic on" : "Mic off",
            symbol: micOn ? "mic.fill" : "mic.slash.fill", tint: micOn ? nil : .systemOrange)
        set(cameraButton, title: cameraOn ? "Camera on" : "Camera off",
            symbol: cameraOn ? "video.fill" : "video.slash.fill", tint: cameraOn ? nil : .systemOrange)
    }

    func show() {
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 16))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    private func set(_ button: NSButton, title: String, symbol: String, tint: NSColor?) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.contentTintColor = tint
    }

    @objc private func recordTapped() { onRecordTapped?() }
    @objc private func micTapped() { onMicTapped?() }
    @objc private func cameraTapped() { onCameraTapped?() }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controls = ControlPanel()
    private let recorder = Recorder()
    private let bubble = CameraBubble()
    private var isRecording = false
    private var startedAt = Date()
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private var micOn: Bool {
        get { defaults.object(forKey: "micOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "micOn") }
    }
    private var cameraOn: Bool {
        get { defaults.bool(forKey: "cameraOn") }
        set { defaults.set(newValue, forKey: "cameraOn") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Mac Recorder")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        controls.onRecordTapped = { [weak self] in self?.toggleRecording() }
        controls.onMicTapped = { [weak self] in self?.toggleMic() }
        controls.onCameraTapped = { [weak self] in self?.toggleCamera() }

        registerHotkey()
        refreshControls()
    }

    @objc private func statusItemClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return togglePanel() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Mac Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func togglePanel() {
        if controls.isVisible {
            controls.hide()
        } else {
            refreshControls()
            controls.show()
        }
        syncBubble()
    }

    // The bubble shows only while the panel is open or a recording runs, so the camera stays off otherwise.
    private func syncBubble() {
        guard cameraOn, controls.isVisible || isRecording else { return bubble.hide() }
        do { try bubble.show() } catch {
            cameraOn = false
            refreshControls()
            showError(error.localizedDescription)
        }
    }

    private func refreshControls() {
        controls.update(isRecording: isRecording, micOn: micOn, cameraOn: cameraOn)
    }

    // MARK: Toggles

    private func toggleMic() {
        Task {
            if !micOn, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                return showError("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
            }
            micOn.toggle()
            recorder.setMicEnabled(micOn)
            refreshControls()
        }
    }

    private func toggleCamera() {
        Task { await setCamera(!cameraOn) }
    }

    @MainActor private func setCamera(_ on: Bool) async {
        if on {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                cameraOn = false
                refreshControls()
                return showError("Camera access is off. Turn it on in System Settings > Privacy & Security > Camera.")
            }
        }
        cameraOn = on
        syncBubble()
        refreshControls()
    }

    // MARK: Recording

    private func toggleRecording() {
        Task { isRecording ? await stopRecording() : await startRecording() }
    }

    @MainActor private func startRecording() async {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            return showError("Screen recording access is off. Turn it on in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen the app.")
        }
        if micOn, !(await AVCaptureDevice.requestAccess(for: .audio)) { micOn = false }
        do {
            try await recorder.start(excludingWindowIDs: [controls.windowID], micEnabled: micOn)
        } catch {
            return showError(error.localizedDescription)
        }
        isRecording = true
        startedAt = Date()
        controls.hide()
        syncBubble()
        startTimer()
        refreshControls()
    }

    @MainActor private func stopRecording() async {
        let url = await recorder.stop()
        isRecording = false
        timer?.invalidate()
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = nil
        controls.hide()
        syncBubble()
        refreshControls()
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func startTimer() {
        statusItem.button?.contentTintColor = .systemRed
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let seconds = Int(Date().timeIntervalSince(self.startedAt))
            self.statusItem.button?.title = String(format: " %02d:%02d", seconds / 60, seconds % 60)
        }
    }

    // MARK: Hotkey

    private func registerHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { controller.togglePanel() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let configured = defaults.string(forKey: hotkeyDefaultsKey) ?? defaultHotkey
        guard let hotkey = parseHotkey(configured) else {
            return showError("The shortcut \"\(configured)\" is not valid. Use a format like cmd+shift+9.")
        }
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_434B), id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { showError("Could not register \(configured). Another app may already use it.") }
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Mac Recorder"
            alert.informativeText = message
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
