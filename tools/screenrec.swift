// Records the main display with the system's sound to an H.264 .mov at a
// constant 59.94 frames a second (60000/1001), until it is told to stop.
//
// ScreenCaptureKit only sends a frame when the picture changes, and sends
// them at the display's own rate. Here every frame is put in the 59.94 slot
// its time falls in; a slot nothing arrived for repeats the frame before it.
// The file is written in fragments, so it can still be opened if the
// recorder is killed.
//
// Stop with SIGINT or SIGTERM, or by creating <out.mov>.stop.
// usage: screenrec <out.mov> [width height] [--max-seconds N] [--no-cursor]
// build: swiftc -O screenrec.swift -o screenrec
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)
var positional: [String] = []
var maxSeconds = 3.0 * 3600
var showCursor = true
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--max-seconds": maxSeconds = Double(it.next() ?? "") ?? maxSeconds
    case "--no-cursor": showCursor = false
    default: positional.append(a)
    }
}
guard let outPath = positional.first else {
    print("usage: screenrec <out.mov> [width height] [--max-seconds N] [--no-cursor]")
    exit(2)
}
let outWidth = positional.count > 2 ? Int(positional[1]) ?? 1920 : 1920
let outHeight = positional.count > 2 ? Int(positional[2]) ?? 1080 : 1080
let outURL = URL(fileURLWithPath: outPath)
let stopFile = outPath + ".stop"
let pidFile = outPath + ".pid"
try? FileManager.default.removeItem(at: outURL)
try? FileManager.default.removeItem(atPath: stopFile)

let timescale: CMTimeScale = 60000
let frameTicks: Int64 = 1001

final class Flag {
    private let lock = NSLock()
    private var value = false
    private(set) var reason = ""
    func set(_ why: String) { lock.lock(); if !value { value = true; reason = why }; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
let stop = Flag()

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "screenrec")
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: AVAssetWriterInput
    var startTicks: Int64 = 0      // the first frame's time, in 1/60000 s
    var started = false
    var closed = false
    var lastIndex: Int64 = -1      // the last slot written
    var lastBuffer: CVPixelBuffer?
    var timer: DispatchSourceTimer?
    var captured = 0, written = 0, repeated = 0, late = 0, lost = 0, audioBuffers = 0

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = timescale
        writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 30_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = timescale
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ])
        audio.expectsMediaDataInRealTime = true
        writer.add(audio)
    }

    private func ticks(_ t: CMTime) -> Int64 {
        CMTimeConvertScale(t, timescale: timescale, method: .roundHalfAwayFromZero).value
    }

    private func slot(_ t: CMTime) -> Int64 {
        let d = ticks(t) - startTicks
        return d >= 0 ? (d + frameTicks / 2) / frameTicks : -1
    }

    private func time(ofSlot index: Int64) -> CMTime {
        CMTime(value: startTicks + index * frameTicks, timescale: timescale)
    }

    private func write(_ buffer: CVPixelBuffer, slot index: Int64) {
        var waited = 0
        while !video.isReadyForMoreMediaData && waited < 25 {
            usleep(1000)
            waited += 1
        }
        if video.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time(ofSlot: index)) {
            written += 1
        } else {
            lost += 1
        }
        lastIndex = index
    }

    // Repeats the last frame up to (and including) `index`.
    private func fill(through index: Int64) {
        guard let buffer = lastBuffer, index > lastIndex else { return }
        for i in (lastIndex + 1)...index {
            write(buffer, slot: i)
            repeated += 1
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !closed else { return }
        if type == .audio {
            // (sound before the first frame is dropped: the file starts with the picture)
            if started, ticks(sb.presentationTimeStamp) >= startTicks, audio.isReadyForMoreMediaData {
                audio.append(sb)
                audioBuffers += 1
            }
            return
        }
        guard type == .screen else { return }
        // only complete frames carry an image
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sb.imageBuffer else { return }
        captured += 1
        if !started {
            startTicks = ticks(sb.presentationTimeStamp)
            guard writer.startWriting() else {
                print("error: \(String(describing: writer.error))")
                stop.set("writer failed")
                closed = true
                return
            }
            writer.startSession(atSourceTime: time(ofSlot: 0))
            started = true
            startTimer()
        }
        let index = slot(sb.presentationTimeStamp)
        if index > lastIndex {
            fill(through: index - 1)
            write(buffer, slot: index)
        } else if index < lastIndex {
            late += 1
        }
        // (a frame for a slot that is already taken is dropped: the display
        // refreshes more often than 59.94 times a second)
        lastBuffer = buffer
    }

    // While the picture is still no frames arrive: keep the file's frames
    // coming, a little behind the clock so that a frame on its way is not
    // overtaken.
    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self, self.started, !self.closed else { return }
            self.fill(through: self.slot(CMClockGetTime(CMClockGetHostTimeClock())) - 9)
        }
        t.resume()
        timer = t
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("capture stopped: \(error.localizedDescription)")
        stop.set("capture stopped")
    }

    func status() -> String {
        queue.sync {
            let secs = Double(lastIndex + 1) * Double(frameTicks) / Double(timescale)
            return String(format: "%7.1f s  frames %d (repeated %d)  captured %d  late %d  lost %d  audio buffers %d",
                          secs, written, repeated, captured, late, lost, audioBuffers)
        }
    }

    func finish() async {
        queue.sync {
            timer?.cancel()
            if started {
                fill(through: slot(CMClockGetTime(CMClockGetHostTimeClock())) - 1)
                closed = true
                video.markAsFinished()
                audio.markAsFinished()
                writer.endSession(atSourceTime: time(ofSlot: lastIndex + 1))
            }
            closed = true
        }
        if started { await writer.finishWriting() }
        if let e = writer.error { print("error: \(e)") }
    }
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { stop.set("signal") }
    source.resume()
    return source
}

_ = NSApplication.shared // (ScreenCaptureKit needs a window server connection)
let done = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            print("no display")
            exit(1)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = outWidth
        cfg.height = outHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)   // every frame the display shows
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = showCursor
        cfg.queueDepth = 8
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        let rec = try Recorder(url: outURL, width: outWidth, height: outHeight)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
        try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.queue)
        try stream.addStreamOutput(rec, type: .audio, sampleHandlerQueue: rec.queue)
        try await stream.startCapture()
        try? "\(getpid())\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
        print("recording display \(display.displayID) (\(display.width)x\(display.height)) as \(outWidth)x\(outHeight) at 59.94 fps with sound, pid \(getpid())")
        print("-> \(outURL.path)")
        let t0 = Date()
        var nextReport = 2.0
        while !stop.isSet {
            try await Task.sleep(nanoseconds: 100_000_000)
            let elapsed = Date().timeIntervalSince(t0)
            if elapsed >= maxSeconds { stop.set("time limit") }
            if FileManager.default.fileExists(atPath: stopFile) { stop.set("stop file") }
            if elapsed >= nextReport {
                print(rec.status())
                nextReport = elapsed < 10 ? nextReport + 2 : nextReport + 30
            }
        }
        try? await stream.stopCapture()
        await rec.finish()
        try? FileManager.default.removeItem(atPath: stopFile)
        try? FileManager.default.removeItem(atPath: pidFile)
        print("stopped (\(stop.reason))")
        print(rec.status())
        print("saved \(outURL.path)")
    } catch {
        print("error: \(error)")
        try? FileManager.default.removeItem(atPath: pidFile)
        exit(1)
    }
    done.signal()
}
done.wait()
