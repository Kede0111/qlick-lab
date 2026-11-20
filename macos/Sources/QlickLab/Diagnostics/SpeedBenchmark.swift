#if DEBUG || SPEKTRAFILM_BENCHMARK
import AppKit
import Darwin

/// SPEKTRAFILM_BENCHMARK_SPEED=<folder>: the speed test the lab's branches are compared with (the same file in each
/// build measured). Opens the folder's first photograph, lets the work done ahead finish, then steps through the
/// photographs at a resting pace and quickly (as with a key held down), switches films quickly, drags a slider, and
/// reports what each took, how long the main thread stayed busy, the memory of the lab and its helpers, and what they
/// wrote to disk. One line a measure on stderr, `speed: <name> <value>`. Compiled in debug builds and with
/// -DSPEKTRAFILM_BENCHMARK, never in the app the lab ships.
@MainActor final class SpeedBenchmark {
    private let model: EditorModel
    private let folder: URL
    private var timer: Timer?
    private var phase = 0, phaseStart = Date(), launched = Date()
    private var awake = CFAbsoluteTimeGetCurrent(), busiest = 0.0
    private var stepsDone = 0, stepStart = Date(), shown: Double?, any: Double?, idleSince: Date?
    private var developedNow: [Double] = [], firstDeveloped: [Double] = [], settled: [Double] = [], hitches: [Double] = []
    private var quickShown = 0, quickSteps = 0
    private var films: [String] = [], filmIndex = 0, switchSettled: [Double] = []
    private var dragFrames = 0, lastImage: IOSurface?, dragIntervals: [Double] = [], lastFrame = Date()
    private var memory = Memory()
    private static var running: SpeedBenchmark?

    static func start(_ model: EditorModel) {
        guard let path = ProcessInfo.processInfo.environment["SPEKTRAFILM_BENCHMARK_SPEED"] else { return }
        let benchmark = SpeedBenchmark(model: model, folder: URL(fileURLWithPath: path))
        running = benchmark
        benchmark.run()
    }

    private init(model: EditorModel, folder: URL) {
        self.model = model
        self.folder = folder
    }

    private func run() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting { self.awake = now } else { self.busiest = max(self.busiest, (now - self.awake) * 1000) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let timer = Timer(timeInterval: 1.0 / 250, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let sampler = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.memory.sample() } }
        RunLoop.main.add(sampler, forMode: .common)
    }

    private var elapsed: Double { Date().timeIntervalSince(phaseStart) * 1000 }
    private var settledNow: Bool { model.previewCurrent && !model.brightnessMatchPending && !model.rendering }
    /// The photograph shows developed: its develop, or its kept develop.
    private var developedShown: Bool { model.image != nil || model.showsKeptRender }
    private var backgroundIdle: Bool {
        !model.lab.previewBuilder.running && model.thumbnailsLeft == 0 && !model.lab.proxyMaker.busy && model.thumbnailsDeveloping.isEmpty
    }

    private func next(_ phase: Int) { self.phase = phase; phaseStart = Date() }

    private func tick() {
        switch phase {
        case 0 where model.ready:
            let photos = (try? PhotoFolder.images(in: folder)) ?? []
            guard let first = photos.first else { report("error", "no photographs in \(folder.path)"); return finish() }
            report("launch_ready_ms", Date().timeIntervalSince(launched) * 1000)
            model.open(first)
            next(1)
        case 1 where settledNow && model.image != nil:
            report("first_open_developed_ms", elapsed)
            films = Array(model.listedFilms.map(\.id).filter { $0 != model.film }.prefix(6))
            next(2)
        case 2:
            // The work done ahead (proxies, thumbnails, previews): until it has rested 4 s.
            if backgroundIdle && settledNow {
                if idleSince == nil { idleSince = Date() }
                if Date().timeIntervalSince(idleSince!) > 4 {
                    report("ahead_work_done_ms", elapsed - 4000)
                    report("memory_app_after_ahead_mb", Memory.footprint(getpid()) / 1e6)
                    next(3); startStep(1)
                }
            } else { idleSince = nil }
            if elapsed > 300_000 { report("ahead_work_done_ms", -1); next(3); startStep(1) }
        case 3:
            // Resting pace: 8 steps forward, 8 back, each once the last has settled and rested.
            watchStep()
            if elapsed > 30_000 { report("error", "a step didn't settle"); return finish() }
            guard settledNow, let shown else { return }
            settled.append(elapsed); developedNow.append(shown); firstDeveloped.append(any ?? shown); hitches.append(busiest)
            stepsDone += 1
            if stepsDone == 16 {
                summary("rest_step")
                stepsDone = 0; next(4)
                return
            }
            next(30)
        case 30 where elapsed > 600:
            next(3); startStep(stepsDone < 8 ? 1 : -1)
        case 4 where elapsed > 800:
            // Quick: a step every 100 ms, 8 forward then 8 back.
            quickSteps = 0; quickShown = 0; next(5); startStep(1)
        case 5:
            watchStep()
            guard elapsed >= 100 else { return }
            quickSteps += 1
            if shown != nil { quickShown += 1 }
            if quickSteps == 8 || quickSteps == 16 {
                next(6)
            } else {
                next(5); startStep(quickSteps < 8 ? 1 : -1)
            }
        case 6:
            guard settledNow, model.image != nil else {
                if elapsed > 30_000 { report("error", "quick steps didn't settle"); finish() }
                return
            }
            report("quick_steps_settled_after_last_ms", elapsed)
            if quickSteps == 8 { next(7) } else {
                report("quick_steps_developed_at_once", Double(quickShown))
                report("quick_steps", Double(quickSteps))
                next(8)
            }
        case 7 where elapsed > 800:
            next(5); startStep(-1)
        case 8 where elapsed > 800:
            // Films, 150 ms apart.
            guard !films.isEmpty else { next(10); return }
            filmIndex = 0; busiest = 0; next(9); model.chooseFilm(films[0])
        case 9:
            if filmIndex < films.count - 1 {
                guard elapsed >= 150 else { return }
                filmIndex += 1; model.chooseFilm(films[filmIndex]); phaseStart = Date()
                return
            }
            guard settledNow else {
                if elapsed > 30_000 { report("error", "films didn't settle"); finish() }
                return
            }
            switchSettled.append(elapsed)
            report("film_switches_settled_after_last_ms", elapsed)
            report("film_switches_main_busiest_ms", busiest)
            if switchSettled.count < 3 { films.reverse(); next(8) } else { next(10) }
        case 10 where elapsed > 800 && settledNow:
            model.beginInteraction(); busiest = 0; dragFrames = 0; dragIntervals = []; lastImage = model.image; lastFrame = Date()
            next(11)
        case 11:
            let t = elapsed / 1000
            if model.image !== lastImage {
                dragFrames += 1; lastImage = model.image
                if dragFrames > 1 { dragIntervals.append(Date().timeIntervalSince(lastFrame) * 1000) }
                lastFrame = Date()
            }
            if t < 3 {
                model.set("enlarger.print_exposure", .number(EditorModel.snap(1 + 0.5 * sin(t * 2), to: 0.1...5, step: 0.01)))
            } else {
                model.endInteraction(); next(12)
                report("drag_fps", Double(dragFrames) / 3)
                report("drag_frame_interval_p50_ms", Self.percentile(dragIntervals, 50))
                report("drag_main_busiest_ms", busiest)
            }
        case 12 where settledNow:
            report("drag_release_settled_ms", elapsed)
            next(13)
        case 13 where elapsed > 1000:
            memory.sample()
            report("memory_app_peak_mb", memory.appPeak / 1e6)
            report("memory_helpers_peak_mb", memory.helpersPeak / 1e6)
            report("memory_total_peak_mb", memory.totalPeak / 1e6)
            report("memory_app_end_mb", Memory.footprint(getpid()) / 1e6)
            report("disk_written_app_mb", memory.appWritten / 1e6)
            report("disk_written_helpers_mb", memory.helpersWritten / 1e6)
            report("render_ahead_hits", Double(Self.aheadHits(model)))
            finish()
        default: break
        }
    }

    private func startStep(_ offset: Int) {
        shown = nil; any = nil; busiest = 0; stepStart = Date()
        model.step(by: offset)
        watchStep()
    }

    /// The first moment the step shows its photograph developed (its kept develop or its develop), and anything.
    private func watchStep() {
        let t = Date().timeIntervalSince(stepStart) * 1000
        if any == nil, model.image != nil || model.placeholder != nil || model.standIn != nil { any = t }
        if shown == nil, developedShown { shown = t }
    }

    private func summary(_ name: String) {
        report("\(name)_developed_shown_p50_ms", Self.percentile(developedNow, 50))
        report("\(name)_developed_shown_max_ms", developedNow.max() ?? -1)
        report("\(name)_settled_p50_ms", Self.percentile(settled, 50))
        report("\(name)_settled_max_ms", settled.max() ?? -1)
        report("\(name)_main_busiest_p50_ms", Self.percentile(hitches, 50))
        report("\(name)_main_busiest_max_ms", hitches.max() ?? -1)
        report("\(name)_developed_at_once", Double(developedNow.filter { $0 < 17 }.count))
        report("\(name)_count", Double(developedNow.count))
    }

    private static func aheadHits(_ model: EditorModel) -> Int {
        // The branch measured may not hold photographs ahead; a mirror finds what it has.
        Mirror(reflecting: model).children.first { $0.label == "_renderAhead" || $0.label == "renderAhead" }
            .flatMap { child in Mirror(reflecting: child.value).children.first { $0.label == "hits" }?.value as? Int } ?? -1
    }

    private func finish() {
        timer?.invalidate()
        NSApp.terminate(nil)
    }

    private static func percentile(_ values: [Double], _ p: Int) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, sorted.count * p / 100)]
    }

    private func report(_ name: String, _ value: Double) {
        FileHandle.standardError.write(Data("speed: \(name) \(String(format: "%.1f", value))\n".utf8))
    }

    private func report(_ name: String, _ text: String) {
        FileHandle.standardError.write(Data("speed: \(name) \(text)\n".utf8))
    }

    /// The lab's and its helpers' memory (physical footprint) and what they wrote to disk.
    struct Memory {
        var appPeak = 0.0, helpersPeak = 0.0, totalPeak = 0.0
        /// Each process's last count of bytes written, so helpers that quit still count.
        var written: [pid_t: Double] = [:]
        var appWritten: Double { written[getpid()] ?? 0 }
        var helpersWritten: Double { written.filter { $0.key != getpid() }.values.reduce(0, +) }

        mutating func sample() {
            let app = Self.footprint(getpid())
            var helpers = 0.0
            for child in Self.children() {
                helpers += Self.footprint(child)
                if let bytes = Self.written(child) { written[child] = max(written[child] ?? 0, bytes) }
            }
            if let bytes = Self.written(getpid()) { written[getpid()] = bytes }
            appPeak = max(appPeak, app); helpersPeak = max(helpersPeak, helpers); totalPeak = max(totalPeak, app + helpers)
        }

        static func usage(_ pid: pid_t) -> rusage_info_v4? {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return result == 0 ? info : nil
        }

        static func footprint(_ pid: pid_t) -> Double { usage(pid).map { Double($0.ri_phys_footprint) } ?? 0 }
        static func written(_ pid: pid_t) -> Double? { usage(pid).map { Double($0.ri_diskio_byteswritten) } }

        static func children() -> [pid_t] {
            var pids = [pid_t](repeating: 0, count: 256)
            let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { return [] }
            return Array(pids.prefix(Int(count))).filter { $0 > 0 }
        }
    }
}
#endif
