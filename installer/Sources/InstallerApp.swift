// Media Center Installer: makes a Mac app of Windows Media Center from the
// person's own Windows 7 disc image. The work is done by the project's
// tools/make_app.sh (carried in the app's Resources/project); this window
// chooses its inputs and shows its progress lines ("step: ...", "error: ...").
//
// It runs on macOS 11 and later: SwiftUI's views in an AppKit window (the
// one-window scene and content-sized windows came in macOS 13), and no Swift
// concurrency (whose runtime macOS 11 does not have).
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The window is the delegate's; this scene only brings the menus.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var snapshotTimer: Timer?
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?
    private var watch: AnyCancellable?
    private let model = BuildModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ note: Notification) {
        let host = NSHostingView(rootView: AnyView(ContentView().environmentObject(model).frame(width: 620)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Media Center Installer"
        window.contentView = host
        window.isReleasedWhenClosed = false
        self.window = window
        self.host = host
        // The window follows its content (the step list grows as the build goes).
        watch = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.fit() } }
        if snapshotTimer != nil {
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))   // drawn, but nowhere on screen
            window.orderFrontRegardless()
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func fit() {
        guard let window = window, let host = host else { return }
        let size = host.fittingSize
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)   // the top stays put
        if frame != old { window.setFrame(frame, display: true, animate: window.isVisible && snapshotTimer == nil) }
    }

    // Unattended checks: --snapshots DIR keeps the app out of the Dock and
    // never activates it, and saves a picture of its window every 3 seconds;
    // --quit-after SECONDS ends it.
    func applicationWillFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count {
            NSApp.setActivationPolicy(.prohibited)
            let dir = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var n = 0
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                n += 1
                AppDelegate.snapshot(to: dir.appendingPathComponent(String(format: "window-%03d.png", n)))
            }
        }
        if let i = args.firstIndex(of: "--quit-after"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    static func snapshot(to url: URL) {
        // SwiftUI draws in Core Animation layers, which cacheDisplay leaves
        // out: render the window's layer tree instead.
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }),
              let frameView = window.contentView?.superview ?? window.contentView else { return }
        frameView.wantsLayer = true
        guard let layer = frameView.layer else { return }
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill()
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: - The build

struct BuildStep: Identifiable {
    enum State { case running, done, failed }
    let id = UUID()
    let text: String
    var state: State
}

final class BuildModel: ObservableObject {
    enum Phase: Equatable {
        case setup
        case running
        case finished(URL)
        case failed(String)
    }

    @Published var source: URL?
    @Published var output: URL
    @Published var work: URL
    @Published var phase: Phase = .setup
    @Published var steps: [BuildStep] = []
    @Published var log = ""
    @Published var fraction = 0.0            // how far the build is (make_app's "progress:" lines)

    private var process: Process?
    private var pending = ""
    private var lastError: String?
    private var madePath: String?
    private var cancelled = false
    private var quitWhenDone = false

    init() {
        let fm = FileManager.default
        output = fm.isWritableFile(atPath: "/Applications")
            ? URL(fileURLWithPath: "/Applications")
            : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        work = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Windows Media Center Builder")
        readArguments()
    }

    var canStart: Bool { source != nil && phase != .running }

    var sourceDescription: String {
        guard let source = source else { return "" }
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func accept(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "iso" else { return false }
        source = url
        if case .failed = phase { phase = .setup }
        return true
    }

    func start() {
        guard let source = source, canStart else { return }
        guard let script = Bundle.main.url(forResource: "make_app", withExtension: "sh", subdirectory: "project/tools") else {
            phase = .failed("This installer is incomplete: its copy of the project's tools is missing.")
            return
        }
        steps = []
        log = ""
        pending = ""
        lastError = nil
        madePath = nil
        cancelled = false
        fraction = 0
        phase = .running

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, source.path, "--output", output.path, "--work", work.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.received(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(), let text = String(data: rest, encoding: .utf8) {
                    self?.received(text)
                }
                self?.finished(status: status)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed("Could not start the build: \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard let p = process, p.isRunning else { return }
        cancelled = true
        p.terminate()
    }

    private func received(_ text: String) {
        pending += text
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("progress: ") {
            if let value = Double(line.dropFirst(10)) { fraction = max(fraction, min(1, value)) }
            return
        }
        log += line + "\n"
        if log.count > 400_000 { log = String(log.suffix(300_000)) }
        if line.hasPrefix("step: ") {
            finishRunningStep(.done)
            steps.append(BuildStep(text: String(line.dropFirst(6)), state: .running))
        } else if line.hasPrefix("error: ") {
            lastError = String(line.dropFirst(7))
        } else if line.hasPrefix("made: ") {
            var path = String(line.dropFirst(6))
            if let paren = path.range(of: " (", options: .backwards) { path = String(path[..<paren.lowerBound]) }
            madePath = path
        }
    }

    private func finishRunningStep(_ state: BuildStep.State) {
        if let i = steps.lastIndex(where: { $0.state == .running }) { steps[i].state = state }
    }

    private func finished(status: Int32) {
        process = nil
        if status == 0, let madePath = madePath {
            fraction = 1
            finishRunningStep(.done)
            phase = .finished(URL(fileURLWithPath: madePath))
        } else {
            finishRunningStep(.failed)
            phase = .failed(cancelled ? "Stopped." : (lastError ?? "The build stopped (status \(status)). The details below say where."))
        }
        if quitWhenDone { NSApp.terminate(nil) }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Windows 7 disc image (.iso)"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { _ = accept(url) }
    }

    func chooseFolder(_ which: ReferenceWritableKeyPath<BuildModel, URL>, message: String) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = self[keyPath: which]
        if panel.runModal() == .OK, let url = panel.url { self[keyPath: which] = url }
    }

    // For unattended checks: --source PATH --output DIR --work DIR --start --quit-when-done
    private func readArguments() {
        var args = Array(CommandLine.arguments.dropFirst())
        var start = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--source" where !args.isEmpty: source = URL(fileURLWithPath: args.removeFirst())
            case "--output" where !args.isEmpty: output = URL(fileURLWithPath: args.removeFirst())
            case "--work" where !args.isEmpty: work = URL(fileURLWithPath: args.removeFirst())
            case "--start": start = true
            case "--quit-when-done": quitWhenDone = true
            default: break
            }
        }
        if start { DispatchQueue.main.async { self.start() } }
    }
}

// MARK: - The window

struct ContentView: View {
    @EnvironmentObject private var model: BuildModel

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider()
            switch model.phase {
            case .setup:
                SetupView()
            case .running, .finished, .failed:
                ProgressPane()
            }
        }
    }
}

struct Header: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Media Center Installer")
                    .font(.title2.weight(.semibold))
                Text("Makes a Mac app of Windows Media Center from your own Windows 7 disc.")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: BuildModel
    @State private var dropTargeted = false
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SourcePicker(dropTargeted: $dropTargeted)

            VStack(alignment: .leading, spacing: 4) {
                FolderRow(title: "Put the app in", url: model.output) {
                    model.chooseFolder(\.output, message: "Choose where to put Windows Media Center")
                }
                if FileManager.default.fileExists(atPath: model.output.appendingPathComponent("Windows Media Center.app").path) {
                    Text("The Windows Media Center app already there will be replaced. Its settings are kept.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            DisclosureGroup("Options", isExpanded: $showOptions) {
                FolderRow(title: "Work folder", url: model.work) {
                    model.chooseFolder(\.work, message: "Choose a folder for the tools and the build (about 800 MB)")
                }
                .padding(.top, 6)
                Text("Tools, the unpacked files and the build are kept here between runs (about 800 MB).")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Make App") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.canStart)
            }
        }
        .padding(20)
    }
}

struct SourcePicker: View {
    @EnvironmentObject private var model: BuildModel
    @Binding var dropTargeted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows 7 disc image")
                .font(.headline)
            HStack(spacing: 14) {
                Image(systemName: model.source == nil ? "opticaldisc" : "opticaldisc.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(model.source == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    if let source = model.source {
                        Text(source.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.sourceDescription)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Drop a .iso file here")
                        Text("Home Premium, Professional, Ultimate or Enterprise, 64-bit")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(model.source == nil ? "Choose…" : "Change…") { model.chooseSource() }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: model.source == nil ? [5, 4] : []))
                    .foregroundColor(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            )
            .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    DispatchQueue.main.async { _ = model.accept(url) }
                }
                return true
            }
        }
    }
}

struct FolderRow: View {
    let title: String
    let url: URL
    let choose: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Change…", action: choose)
        }
    }
}

struct ProgressPane: View {
    @EnvironmentObject private var model: BuildModel
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text("\(Int((model.fraction * 100).rounded()))%")
                        .font(Font.body.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                ProgressView(value: model.fraction)
                    .progressViewStyle(LinearProgressViewStyle())
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.steps) { step in
                    HStack(spacing: 9) {
                        Group {
                            switch step.state {
                            case .running:
                                ProgressView().controlSize(.small)
                            case .done:
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            case .failed:
                                Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                            }
                        }
                        .frame(width: 18)
                        Text(step.text)
                            .foregroundColor(step.state == .running ? .primary : .secondary)
                    }
                }
                if model.steps.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small).frame(width: 18)
                        Text("Starting").foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .failed(let why) = model.phase {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .selectableText()
            }

            DisclosureGroup("Details", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log)
                            .font(.system(.caption, design: .monospaced))
                            .selectableText()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("log")
                    }
                    .frame(height: 180)
                    .onReceive(model.$log) { _ in proxy.scrollTo("log", anchor: .bottom) }
                }
            }

            HStack {
                Spacer()
                switch model.phase {
                case .running:
                    Button("Stop") { model.cancel() }
                case .finished(let app):
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                    Button("Open Windows Media Center") {
                        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                    .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Back") { model.phase = .setup }
                    Button("Try Again") { model.start() }
                        .keyboardShortcut(.defaultAction)
                case .setup:
                    EmptyView()
                }
            }
            .controlSize(.large)
        }
        .padding(20)
    }

    private var title: String {
        switch model.phase {
        case .running: return "Making Windows Media Center"
        case .finished: return "Windows Media Center is ready"
        case .failed: return "The app was not made"
        case .setup: return ""
        }
    }
}

extension View {
    /// Selectable text where macOS offers it (12 and later).
    @ViewBuilder func selectableText() -> some View {
        if #available(macOS 12.0, *) {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}
