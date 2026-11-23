import AppKit
import Darwin

struct CaptureError: Error, CustomStringConvertible {
    let description: String
}

final class JSONL {
    let file: FileHandle
    let url: URL
    let initialByteCount: Int
    private var buffer = Data()

    init(_ url: URL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CaptureError(description: "Cannot create \(url.path)")
            }
        }
        file = try FileHandle(forWritingTo: url)
        initialByteCount = Int(try file.seekToEnd())
    }

    func append(_ row: [String: Any]) throws {
        buffer.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        buffer.append(10)
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try file.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

struct SwipeBin: Hashable, Sendable {
    let device: String
    let speed: String
    let direction: String
}

enum TrialScenario: String, CaseIterable, Sendable {
    case swipe
    case recontact = "re-contact"
    case repeatFlick = "repeat"
    case reversal

    func target(for bin: SwipeBin) -> Int? {
        guard ["up", "down"].contains(bin.direction) else { return nil }
        if self == .swipe { return 8 }
        return bin.speed == "medium" ? 4 : nil
    }
}

struct SessionProgress: Sendable {
    private struct Group: Hashable, Sendable {
        let label: String
        let transport: String
        let scenario: TrialScenario
    }

    private var counts: [Group: [SwipeBin: Int]] = [:]

    init() {}

    init(contentsOf url: URL, byteCount: Int) throws {
        guard byteCount > 0 else { return }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let text = String(decoding: try file.read(upToCount: byteCount) ?? Data(), as: UTF8.self)
        var trials: [String: [[String: Any]]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = row["trial"] as? String else { continue }
            trials[id, default: []].append(row)
        }
        for rows in trials.values { record(rows) }
    }

    mutating func record(_ rows: [[String: Any]]) {
        guard let begin = rows.first(where: { $0["kind"] as? String == "begin" }),
              let end = rows.firstIndex(where: { $0["kind"] as? String == "end" }),
              !rows.contains(where: { $0["kind"] as? String == "discard" }),
              let scenarioName = begin["scenario"] as? String,
              let scenario = TrialScenario(rawValue: scenarioName),
              let label = begin["firmware"] as? String, let transport = begin["transport"] as? String,
              let device = begin["device"] as? String, let speed = begin["speed"] as? String,
              let direction = begin["direction"] as? String,
              rows.contains(where: { $0["kind"] as? String == "wheel" }),
              Self.hasMotion(rows, direction: direction)
        else { return }
        if begin["expect_trace"] as? Bool == true,
           !Self.hasCompleteTrace(rows, after: end, token: (begin["trace_token"] as? NSNumber)?.intValue,
                                  transport: transport) { return }
        let group = Group(label: label, transport: transport, scenario: scenario)
        counts[group, default: [:]][SwipeBin(device: device, speed: speed, direction: direction), default: 0] += 1
    }

    mutating func merge(_ other: SessionProgress) {
        for (group, bins) in other.counts {
            counts[group, default: [:]].merge(bins, uniquingKeysWith: +)
        }
    }

    func count(_ bin: SwipeBin, label: String, transport: String, scenario: TrialScenario) -> Int {
        counts[Group(label: label, transport: transport, scenario: scenario)]?[bin] ?? 0
    }

    private static func hasMotion(_ rows: [[String: Any]], direction: String) -> Bool {
        let points = rows.compactMap { row -> CGPoint? in
            guard row["kind"] as? String == "viewport",
                  let x = (row["x"] as? NSNumber)?.doubleValue,
                  let y = (row["y"] as? NSNumber)?.doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard let first = points.first, let last = points.last else { return false }
        let axis: CGVector
        switch direction {
        case "up": axis = CGVector(dx: 0, dy: -1)
        case "down": axis = CGVector(dx: 0, dy: 1)
        case "left": axis = CGVector(dx: -1, dy: 0)
        case "right": axis = CGVector(dx: 1, dy: 0)
        case "diagonal":
            let dx = last.x - first.x, dy = last.y - first.y
            axis = dx == 0 && dy == 0 ? CGVector(dx: 0, dy: 1) : CGVector(dx: dx, dy: dy)
        default: return false
        }
        let project = { (point: CGPoint) in
            (point.x - first.x) * axis.dx + (point.y - first.y) * axis.dy
        }
        return points.contains { project($0) != 0 }
    }

    private static func hasCompleteTrace(_ rows: [[String: Any]], after end: Int,
                                         token: Int?, transport: String) -> Bool {
        guard let token else { return false }
        let trace = rows.enumerated().filter { ($0.element["kind"] as? String ?? "").hasPrefix("trace_") }
        guard trace.count >= 4, trace[0].offset < end, trace[1].offset > end,
              trace[0].element["kind"] as? String == "trace_ready",
              trace[1].element["kind"] as? String == "trace_begin",
              trace.last?.element["kind"] as? String == "trace_end",
              trace.allSatisfy({ ($0.element["sequence"] as? NSNumber)?.intValue == token }),
              trace[1].element["overflow"] as? Bool == false,
              trace[1].element["transport"] as? String == transport,
              trace[1].element["count"] as? Int == trace.count - 3
        else { return false }
        var hasInput = false
        var coasting = false
        for (_, row) in trace.dropFirst(2).dropLast() {
            guard row["kind"] as? String == "trace_event", let event = row["event"] as? Int else { return false }
            switch event {
            case 1: hasInput = true
            case 2:
                guard !coasting else { return false }
                coasting = true
            case 4, 5:
                guard coasting else { return false }
                coasting = false
            case 3, 7, 8, 9:
                guard coasting else { return false }
            default: break
            }
        }
        return hasInput && !coasting
    }
}

final class SerialTrace {
    private let source: DispatchSourceRead
    private let fd: Int32
    private var line = Data()

    init(path: String, receive: @escaping (String) -> Void,
         disconnected: @escaping () -> Void) throws {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw CaptureError(description: "Cannot open serial device \(path): \(String(cString: strerror(errno)))") }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            close(fd)
            throw CaptureError(description: "Cannot read serial settings")
        }
        cfmakeraw(&options)
        _ = cfsetspeed(&options, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            close(fd)
            throw CaptureError(description: "Cannot set serial settings")
        }
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &bytes, bytes.count)
            guard let self else { return }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                self.source.cancel()
                disconnected()
                return
            }
            guard count > 0 else { return }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    receive(String(decoding: self.line, as: UTF8.self))
                    self.line.removeAll(keepingCapacity: true)
                } else if self.line.count < 4096 {
                    self.line.append(byte)
                }
            }
        }
        source.resume()
    }

    deinit { source.cancel() }

    func command(_ action: Character, token: UInt32) throws {
        let bytes = Array("\n\(action) \(token)\n".utf8)
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else {
            throw CaptureError(description: "Could not send the firmware trace command. Check the USB connection and retry.")
        }
    }
}

final class Grid: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirty.fill()
        NSColor.separatorColor.setStroke()
        let step = 40
        let grid = NSBezierPath()
        for x in stride(from: Int(dirty.minX) / step * step, through: Int(dirty.maxX), by: step) {
            grid.move(to: NSPoint(x: CGFloat(x), y: dirty.minY))
            grid.line(to: NSPoint(x: CGFloat(x), y: dirty.maxY))
        }
        for y in stride(from: Int(dirty.minY) / step * step, through: Int(dirty.maxY), by: step) {
            grid.move(to: NSPoint(x: dirty.minX, y: CGFloat(y)))
            grid.line(to: NSPoint(x: dirty.maxX, y: CGFloat(y)))
            for x in stride(from: Int(dirty.minX) / 240 * 240, through: Int(dirty.maxX), by: 240) {
                ("\(x), \(y)" as NSString).draw(at: NSPoint(x: x + 4, y: y + 4), withAttributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                ])
            }
        }
        grid.stroke()
    }
}

final class ScrollPane: NSScrollView {
    var onWheel: ((NSEvent) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    private var boundsObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        documentView = Grid(frame: NSRect(x: 0, y: 0, width: 24000, height: 24000))
        hasVerticalScroller = true
        hasHorizontalScroller = true
        borderType = .bezelBorder
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.onMove?(self.contentView.bounds.origin)
        }
    }

    required init?(coder: NSCoder) { fatalError("ScrollPane is programmatic") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    func recenter() {
        contentView.scroll(to: NSPoint(x: 12000, y: 12000))
        reflectScrolledClipView(contentView)
    }

    func highlight(_ color: NSColor?) {
        wantsLayer = true
        layer?.borderColor = color?.cgColor
        layer?.borderWidth = color == nil ? 0 : 3
    }

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
        super.scrollWheel(with: event)
    }
}

enum TrialFeedback {
    case ready, arming, recording, transferring, saved, warning

    var tint: NSColor {
        switch self {
        case .ready: return .secondaryLabelColor
        case .arming, .transferring: return .systemBlue
        case .recording: return .systemRed
        case .saved: return .systemGreen
        case .warning: return .systemOrange
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "keyboard"
        case .arming: return "antenna.radiowaves.left.and.right"
        case .recording: return "record.circle"
        case .transferring: return "arrow.down.circle"
        case .saved: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

final class TrialBanner: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let transfer = NSProgressIndicator()
    private var feedback = TrialFeedback.ready

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        transfer.style = .bar
        transfer.isIndeterminate = false
        transfer.controlSize = .small
        transfer.alphaValue = 0
        transfer.setAccessibilityHidden(true)
        let copy = NSStackView(views: [title, detail, transfer])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 4
        let row = NSStackView(views: [icon, copy])
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 24),
            detail.widthAnchor.constraint(equalTo: copy.widthAnchor),
            transfer.widthAnchor.constraint(equalTo: copy.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("TrialBanner is programmatic") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = feedback.tint.withAlphaComponent(0.12).cgColor
        layer?.borderColor = feedback.tint.withAlphaComponent(0.35).cgColor
    }

    func show(_ feedback: TrialFeedback, title: String, detail: String) {
        self.feedback = feedback
        self.title.stringValue = title
        self.detail.stringValue = detail
        icon.image = NSImage(systemSymbolName: feedback.symbol, accessibilityDescription: nil)
        icon.contentTintColor = feedback.tint
        transfer.alphaValue = 0
        transfer.setAccessibilityHidden(true)
        needsDisplay = true
    }

    func showTransfer(received: Int, expected: Int) {
        detail.stringValue = "\(received) of \(expected) firmware records received. Wait for Trial saved."
        transfer.maxValue = Double(max(1, expected))
        transfer.doubleValue = Double(received)
        transfer.alphaValue = 1
        transfer.setAccessibilityHidden(false)
    }

    func showHint(_ message: String) {
        detail.stringValue = message
    }
}

final class Recorder: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private let output: JSONL
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let mac = ScrollPane()
    private let cirque = ScrollPane()
    private let speed = NSPopUpButton()
    private let direction = NSPopUpButton()
    private let transport = NSPopUpButton()
    private let scenario = NSPopUpButton()
    private let firmware = NSTextField(string: "baseline")
    private let status = TrialBanner()
    private var progress = SessionProgress()
    private let progressQueue = DispatchQueue(label: "go60.session-progress", qos: .userInitiated)
    private var trialRows: [[String: Any]] = []
    private let progressTitle = NSTextField(labelWithString: "")
    private let speeds = ["slow", "medium", "fast"]
    private let progressDevices = ["MacBook", "MacBook", "Cirque", "Cirque"]
    private var progressHeadings: [NSTextField] = []
    private var progressRows: [[NSTextField]] = []
    private lazy var progressGrid = makeProgressGrid()
    private let serialPath: NSTextField?
    private var serial: SerialTrace?
    private var traceTimeout: Timer?
    private var trial: String?
    private var activeDevice: String?
    private var traceToken: UInt32?
    private var traceReady = false
    private var traceExpectedCount: Int?
    private var traceReceivedCount = 0
    private var traceOverflow = false
    private var expectedTransport: String?
    private var recordedTransport: String?
    private var sessionFailed = false

    init(path: String, serialPath: String?) throws {
        output = try JSONL(URL(fileURLWithPath: path))
        self.serialPath = serialPath.map { NSTextField(string: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Go60 Scroll Tuning"
        window.minSize = NSSize(width: 800, height: 620)
        window.center()
        speed.addItems(withTitles: speeds)
        direction.addItems(withTitles: ["up", "down", "left", "right", "diagonal"])
        transport.addItems(withTitles: ["Bluetooth", "USB"])
        scenario.addItems(withTitles: TrialScenario.allCases.map(\.rawValue))
        for picker in [speed, direction, transport, scenario] {
            picker.target = self
            picker.action = #selector(updateProgress)
        }
        firmware.toolTip = "Firmware candidate label"
        firmware.delegate = self
        firmware.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let settings = NSStackView(views: [speed, direction, scenario, transport, firmware])
        let buttons = NSStackView(views: [
            trialButton("Start / Finish MacBook (⌘1)", key: "1", action: #selector(toggleMacBook)),
            trialButton("Start / Finish Cirque (⌘2)", key: "2", action: #selector(toggleCirque)),
            trialButton("Finish (⌘↩)", key: "\r", action: #selector(finish)),
            trialButton("Discard trial (⇧⌘D)", key: "d", modifiers: [.command, .shift],
                        action: #selector(discard)),
        ])
        let panes = NSStackView(views: [column("MacBook", mac), column("Cirque", cirque)])
        panes.distribution = .fillEqually
        let layout = NSStackView(views: [settings, buttons, status, progressTitle, progressGrid, panes])
        if let serialPath {
            serialPath.setAccessibilityLabel("Go60 USB serial path")
            serialPath.delegate = self
            serialPath.widthAnchor.constraint(equalToConstant: 260).isActive = true
            layout.insertArrangedSubview(NSStackView(views: [
                NSTextField(labelWithString: "USB serial"), serialPath,
                trialButton("Reconnect USB (⇧⌘R)", key: "r", modifiers: [.command, .shift],
                            action: #selector(reconnectUSB)),
            ]), at: 2)
        }
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        layout.spacing = 10
        let content = NSView()
        window.contentView = content
        content.addSubview(layout)
        layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: content.topAnchor),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panes.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -32),
            panes.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            status.widthAnchor.constraint(equalTo: panes.widthAnchor),
        ])

        for (name, pane) in [("macbook", mac), ("cirque", cirque)] {
            pane.onWheel = { [weak self] in self?.record($0, from: name) }
            pane.onMove = { [weak self] in self?.record($0, from: name) }
        }
        showStatus(.ready, "Ready for a trial", "⌘1 MacBook · ⌘2 Cirque · ⇧⌘D discard")
        if serialPath != nil { connectUSB() }
        loadExistingProgress()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeProgressGrid() -> NSGridView {
        let headings = (["Speed"] + progressDevices).map {
            let label = NSTextField(labelWithString: $0)
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            return label
        }
        progressHeadings = Array(headings.dropFirst())
        progressRows = speeds.map { _ in
            progressDevices.map { _ in
                let label = NSTextField(labelWithString: "")
                label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                return label
            }
        }
        let rows = [headings] + zip(speeds, progressRows).map { speed, cells in
            [NSTextField(labelWithString: speed.capitalized)] + cells
        }
        let grid = NSGridView(views: rows)
        grid.xPlacement = .leading
        for label in progressRows.joined() { grid.cell(for: label)?.xPlacement = .fill }
        grid.columnSpacing = 16
        grid.rowSpacing = 3
        grid.column(at: 0).width = 72
        for index in progressDevices.indices {
            let column = grid.column(at: index + 1)
            column.width = 120
            if index > 0, progressDevices[index] != progressDevices[index - 1] {
                column.leadingPadding = 16
            }
        }
        return grid
    }

    func controlTextDidChange(_ notification: Notification) {
        updateProgress()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard command == #selector(NSResponder.insertNewline(_:)) ||
              command == #selector(NSResponder.cancelOperation(_:)) else { return false }
        return window.makeFirstResponder(nil)
    }

    private func endTextEditing() {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            window.makeFirstResponder(nil)
        }
    }

    private func loadExistingProgress() {
        let url = output.url
        // Trials appended while the startup scan runs are counted separately.
        let byteCount = output.initialByteCount
        progressQueue.async { [weak self] in
            let result = Result { try SessionProgress(contentsOf: url, byteCount: byteCount) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let progress):
                    self.progress.merge(progress)
                    self.updateProgress()
                case .failure(let error):
                    self.progressTitle.stringValue = "Could not read session progress: \(error.localizedDescription)"
                    for cell in self.progressRows.joined() {
                        cell.stringValue = "—"
                        cell.textColor = .secondaryLabelColor
                        cell.drawsBackground = false
                    }
                }
            }
        }
    }

    @objc private func updateProgress() {
        let label = firmware.stringValue
        let connection = transport.titleOfSelectedItem ?? "Bluetooth"
        let selectedScenario = TrialScenario(rawValue: scenario.titleOfSelectedItem ?? "") ?? .swipe
        let directions: [String]
        switch direction.titleOfSelectedItem {
        case "left", "right": directions = ["left", "right"]
        case "diagonal": directions = ["diagonal"]
        default: directions = ["up", "down"]
        }
        let arrows = ["up": "↑", "down": "↓", "left": "←", "right": "→", "diagonal": "↗"]
        progressTitle.stringValue = "\(selectedScenario.rawValue.capitalized) progress · \(label.isEmpty ? "(unlabeled)" : label) · \(connection)"
        for (column, device) in progressDevices.enumerated() {
            let directionIndex = column % 2
            progressGrid.column(at: column + 1).isHidden = directionIndex >= directions.count
            guard directionIndex < directions.count else { continue }
            let travel = directions[directionIndex]
            progressHeadings[column].stringValue = "\(device) \(arrows[travel] ?? travel)"
            for (row, speed) in speeds.enumerated() {
                let bin = SwipeBin(device: device.lowercased(), speed: speed, direction: travel)
                let count = progress.count(bin, label: label, transport: connection, scenario: selectedScenario)
                let selected = self.speed.titleOfSelectedItem == speed && direction.titleOfSelectedItem == travel
                styleProgressCell(progressRows[row][column], count: count,
                                  target: selectedScenario.target(for: bin), selected: selected)
            }
        }
    }

    private func styleProgressCell(_ cell: NSTextField, count: Int, target: Int?, selected: Bool) {
        let tint: NSColor?
        var emphasized = false
        if let target {
            let remaining = max(0, target - count)
            cell.stringValue = "\(count)/\(target) · \(remaining) left"
            cell.textColor = remaining == 0 ? .secondaryLabelColor : .labelColor
            emphasized = remaining > 0 && selected
            if emphasized {
                tint = NSColor.systemOrange.withAlphaComponent(0.24)
            } else if remaining > 0 {
                let fraction = CGFloat(remaining) / CGFloat(target)
                tint = NSColor.systemBlue.withAlphaComponent(0.06 + 0.08 * fraction)
            } else {
                tint = NSColor.systemGreen.withAlphaComponent(0.10)
            }
        } else {
            cell.stringValue = "\(count) recorded"
            cell.textColor = .secondaryLabelColor
            tint = nil
        }
        cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                              weight: emphasized ? .semibold : .regular)
        cell.drawsBackground = tint != nil
        cell.backgroundColor = tint ?? .clear
    }

    private func trialButton(_ title: String, key: String,
                             modifiers: NSEvent.ModifierFlags = [.command], action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = modifiers
        return button
    }

    private func column(_ label: String, _ pane: NSScrollView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.font = .boldSystemFont(ofSize: 15)
        let column = NSStackView(views: [title, pane])
        column.orientation = .vertical
        column.alignment = .leading
        pane.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        flush()
    }

    @objc private func toggleMacBook() { toggleTrial("macbook") }
    @objc private func toggleCirque() { toggleTrial("cirque") }

    private func showStatus(_ feedback: TrialFeedback, _ title: String, _ detail: String,
                            device: String? = nil) {
        status.show(feedback, title: title, detail: detail)
        mac.highlight(device == "macbook" ? feedback.tint : nil)
        cirque.highlight(device == "cirque" ? feedback.tint : nil)
    }

    private func toggleTrial(_ device: String) {
        if activeDevice == device {
            finish()
        } else if trial == nil {
            start(device)
        } else if let activeDevice {
            let shortcut = activeDevice == "macbook" ? "⌘1" : "⌘2"
            status.showHint("This trial is still recording. Finish with \(shortcut) or ⌘Return.")
        }
    }

    private func start(_ device: String) {
        guard trial == nil, !sessionFailed else { return }
        endTextEditing()
        let pane = device == "macbook" ? mac : cirque
        let needsTrace = device == "cirque" && serialPath != nil
        if needsTrace, serial == nil, !connectUSB() { return }
        let token = needsTrace ? UInt32.random(in: 1...UInt32.max) : nil
        if let token, !send("A", token: token) { return }
        pane.recenter()
        trial = UUID().uuidString
        traceToken = token
        let connection = transport.titleOfSelectedItem ?? "Bluetooth"
        expectedTransport = token == nil ? nil : connection
        var metadata: [String: Any] = [
            "device": device, "speed": speed.titleOfSelectedItem ?? "slow",
            "direction": direction.titleOfSelectedItem ?? "up",
            "transport": connection,
            "scenario": scenario.titleOfSelectedItem ?? "swipe",
            "firmware": firmware.stringValue, "expect_trace": token != nil,
        ]
        if let token { metadata["trace_token"] = token }
        guard append("begin", metadata) else { return }
        if token != nil {
            showStatus(.arming, "⌘2 accepted · Arming Cirque",
                       "Wait for the red recording border before swiping.", device: device)
            waitForTrace(3, message: "The Go60 didn’t acknowledge the trial.")
        } else {
            beginRecording(device, pane: pane)
        }
    }

    private func beginRecording(_ device: String, pane: ScrollPane) {
        activeDevice = device
        guard append("viewport", ["x": pane.contentView.bounds.origin.x,
                                  "y": pane.contentView.bounds.origin.y]) else { return }
        let shortcut = device == "macbook" ? "⌘1" : "⌘2"
        let name = device == "macbook" ? "MacBook" : "Cirque"
        showStatus(.recording, "Recording · \(name)",
                   "Swipe in the highlighted pane. When motion ends, press \(shortcut) again or ⌘Return.",
                   device: device)
    }

    @objc private func finish() {
        guard let device = activeDevice, !sessionFailed else { return }
        endTextEditing()
        if traceToken != nil {
            showStatus(.transferring, "Finish accepted · Cirque",
                       "Recording stopped. Waiting for the firmware trace before the next trial.", device: device)
        }
        if let traceToken, !send("E", token: traceToken) {
            disconnectUSB("The Go60 USB serial connection stopped accepting commands.")
            return
        }
        activeDevice = nil
        guard append("end"), flush() else { return }
        if traceToken != nil {
            waitForTrace(12, message: "The Go60 didn’t finish sending the trace.")
        } else {
            countSavedTrial()
            let name = device == "macbook" ? "MacBook" : "Cirque"
            showStatus(.saved, "Trial saved · \(name)", "⌘1 MacBook · ⌘2 Cirque", device: device)
        }
    }

    @objc private func discard() {
        guard trial != nil, !sessionFailed else { return }
        let cancelledOnDevice = traceToken.map { send("C", token: $0) } ?? true
        guard append("discard"), flush() else { return }
        resetTrial()
        showStatus(.warning, "Trial discarded", cancelledOnDevice ? "Start a new trial when ready." :
                   "Reconnect the Go60 USB cable before starting another Cirque trial.")
    }

    private func resetTrial() {
        clearTraceTimeout()
        trialRows.removeAll(keepingCapacity: true)
        trial = nil
        activeDevice = nil
        traceToken = nil
        traceReady = false
        traceExpectedCount = nil
        traceReceivedCount = 0
        traceOverflow = false
        expectedTransport = nil
        recordedTransport = nil
    }

    private func countSavedTrial() {
        progress.record(trialRows)
        resetTrial()
        updateProgress()
    }

    @objc private func reconnectUSB() {
        guard !sessionFailed else { return }
        if traceToken != nil {
            disconnectUSB("The active Cirque trial was interrupted.")
        } else {
            serial = nil
        }
        // Allow the old dispatch source's cancel handler to close its descriptor first.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.sessionFailed, self.serial == nil else { return }
            if self.connectUSB(), self.trial == nil {
                self.showStatus(.ready, "Go60 USB serial reconnected", "Start a new trial with ⌘1 or ⌘2.")
            }
        }
    }

    @discardableResult
    private func connectUSB() -> Bool {
        guard let path = serialPath?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        do {
            serial = try SerialTrace(path: path, receive: { [weak self] in self?.receive($0) },
                                     disconnected: { [weak self] in
                                         self?.disconnectUSB("The Go60 USB serial device disconnected.")
                                     })
            return true
        } catch {
            if trial == nil { showStatus(.warning, "USB serial unavailable", "\(error). Use ⇧⌘R to reconnect.") }
            return false
        }
    }

    private func disconnectUSB(_ message: String) {
        serial = nil
        if traceToken != nil {
            guard append("trace_error", ["message": message]), flush() else { return }
            resetTrial()
        }
        if trial == nil, !sessionFailed {
            showStatus(.warning, "Go60 trace interrupted",
                       "\(message) Check the cable, then press ⇧⌘R or start a new Cirque trial.")
        }
    }

    private func clearTraceTimeout() {
        traceTimeout?.invalidate()
        traceTimeout = nil
    }

    private func waitForTrace(_ seconds: TimeInterval, message: String) {
        clearTraceTimeout()
        traceTimeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.disconnectUSB(message)
        }
    }

    private func send(_ action: Character, token: UInt32) -> Bool {
        do {
            try serial?.command(action, token: token)
            return true
        } catch {
            serial = nil
            showStatus(.warning, "Go60 command failed", "\(error) Use ⇧⌘R to reconnect.")
            return false
        }
    }

    private func record(_ event: NSEvent, from device: String) {
        guard activeDevice == device else { return }
        append("wheel", [
            "time": event.timestamp, "dx": event.scrollingDeltaX, "dy": event.scrollingDeltaY,
            "precise": event.hasPreciseScrollingDeltas,
            "phase": event.phase.rawValue, "momentum": event.momentumPhase.rawValue,
        ])
    }

    private func record(_ point: NSPoint, from device: String) {
        guard activeDevice == device else { return }
        append("viewport", ["x": point.x, "y": point.y])
    }

    @discardableResult
    private func append(_ kind: String, _ fields: [String: Any] = [:]) -> Bool {
        guard let trial, !sessionFailed else { return false }
        var row = fields
        row["kind"] = kind
        row["trial"] = trial
        if row["time"] == nil { row["time"] = ProcessInfo.processInfo.systemUptime }
        do {
            try output.append(row)
            trialRows.append(row)
            return true
        } catch {
            sessionFailed = true
            showStatus(.warning, "Capture stopped", String(describing: error))
            return false
        }
    }

    @discardableResult
    private func flush() -> Bool {
        guard !sessionFailed else { return false }
        do {
            try output.flush()
            return true
        } catch {
            sessionFailed = true
            showStatus(.warning, "Capture stopped", String(describing: error))
            return false
        }
    }

    private func receive(_ line: String) {
        guard let marker = line.range(of: "SCROLLTRACE "), let traceToken, !sessionFailed else { return }
        let fields = line[marker.upperBound...].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, UInt32(fields[1]) == traceToken else { return }
        let metadata: [String: Any] = ["sequence": traceToken]
        switch fields[0] {
        case "READY":
            guard fields.count == 2, !traceReady, append("trace_ready", metadata) else { return }
            clearTraceTimeout()
            traceReady = true
            beginRecording("cirque", pane: cirque)
        case "BEGIN":
            guard fields.count == 5, traceReady, activeDevice == nil, traceExpectedCount == nil,
                  let count = Int(fields[2]), let overflow = Int(fields[3]) else { return }
            traceExpectedCount = count
            traceOverflow = overflow != 0
            let connection = String(fields[4])
            recordedTransport = connection
            append("trace_begin", [
                "sequence": traceToken, "count": count,
                "overflow": traceOverflow, "transport": connection,
            ])
            if !sessionFailed {
                showStatus(.transferring, "Receiving trace · Cirque",
                           "Wait for Trial saved before starting another trial.", device: "cirque")
                status.showTransfer(received: 0, expected: count)
            }
        case "EVENT":
            guard fields.count == 6, traceExpectedCount != nil, let time = UInt32(fields[2]),
                  let event = Int(fields[3]), let x = Int(fields[4]), let y = Int(fields[5]) else { return }
            if append("trace_event", [
                "sequence": traceToken, "firmware_us": time, "event": event, "x": x, "y": y,
            ]) {
                traceReceivedCount += 1
                if let traceExpectedCount, traceReceivedCount % 16 == 0 || traceReceivedCount == traceExpectedCount {
                    status.showTransfer(received: traceReceivedCount, expected: traceExpectedCount)
                }
            }
        case "END":
            guard fields.count == 2, let traceExpectedCount,
                  append("trace_end", metadata), flush() else { return }
            let complete = !traceOverflow && traceExpectedCount > 0 && traceExpectedCount == traceReceivedCount
            let mismatch = recordedTransport != expectedTransport
            let connection = recordedTransport ?? "unknown"
            let selectedConnection = expectedTransport ?? "unknown"
            countSavedTrial()
            if !complete {
                showStatus(.warning, "Incomplete trace · Cirque", "This trial was saved for inspection. Repeat the swipe.")
            } else if mismatch {
                showStatus(.warning, "Connection mismatch · Cirque",
                           "Trial excluded from the \(selectedConnection) count. Firmware reported \(connection).")
            } else {
                showStatus(.saved, "Trial and trace saved · Cirque", "⌘2 starts the next Cirque trial.", device: "cirque")
            }
        default:
            return
        }
    }
}

let args = CommandLine.arguments.dropFirst()
if args.count != 1 && !(args.count == 3 && args.dropFirst().first == "--serial") {
    fputs("Usage: scroll-capture SESSION.jsonl [--serial /dev/cu.usbmodem…]\n", stderr)
    exit(2)
}
do {
    let recorder = try Recorder(path: args.first!, serialPath: args.count == 3 ? args.last : nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = recorder
    app.run()
    withExtendedLifetime(recorder) {}
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
