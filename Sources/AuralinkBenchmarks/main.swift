import AuralinkCore
import Darwin
import Dispatch
import Foundation

private struct Configuration {
    var iirIterations = 1_000
    var firIterations = 750
    var warmupIterations = 50
    var label = "standard"

    init(arguments: [String]) {
        if arguments.contains("--help") || arguments.contains("-h") {
            Self.printUsage()
            exit(0)
        }

        let unknown = arguments.filter { $0 != "--quick" }
        guard unknown.isEmpty else {
            fputs("Unknown argument: \(unknown[0])\n\n", stderr)
            Self.printUsage()
            exit(64)
        }

        if arguments.contains("--quick") {
            // Enough samples for p99 not to be the second-largest observation;
            // short OS scheduling preemptions must not masquerade as DSP cost.
            iirIterations = 300
            firIterations = 300
            warmupIterations = 20
            label = "quick"
        }
    }

    private static func printUsage() {
        print("""
        Usage: swift run -c release AuralinkBenchmarks [--quick]

          --quick   Use 100 measured callbacks per case for a shorter smoke run.

        Threshold results are informational and never change the exit status.
        """)
    }
}

private struct Measurement {
    let mode: EQRenderMode
    let sampleRate: Double
    let frames: Int
    let iterations: Int
    let p50Nanoseconds: Double
    let p99Nanoseconds: Double
    let maxNanoseconds: Double
    let heapBytesDelta: Int64
    let heapBlocksDelta: Int64
    let checksum: Double

    var deadlineNanoseconds: Double {
        Double(frames) / sampleRate * 1_000_000_000
    }

    var p99DeadlinePercent: Double {
        p99Nanoseconds / deadlineNanoseconds * 100
    }

    var p99RealtimeMultiplier: Double {
        deadlineNanoseconds / max(p99Nanoseconds, 1)
    }

    var realtimeGatePassed: Bool {
        p99DeadlinePercent <= 25 && maxNanoseconds < deadlineNanoseconds
    }
}

private struct TransitionMeasurement {
    let sampleRate: Double
    let frames: Int
    let p99Nanoseconds: Double
    let maxNanoseconds: Double

    var deadlineNanoseconds: Double {
        Double(frames) / sampleRate * 1_000_000_000
    }

    var p99DeadlinePercent: Double {
        p99Nanoseconds / deadlineNanoseconds * 100
    }

    var gatePassed: Bool {
        p99DeadlinePercent <= 50 && maxNanoseconds < deadlineNanoseconds
    }
}

private struct HeapSnapshot {
    var bytesInUse: UInt64
    var blocksInUse: UInt64
}

private func heapSnapshot() -> HeapSnapshot {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &statistics)
    return HeapSnapshot(
        bytesInUse: UInt64(statistics.size_in_use),
        blocksInUse: UInt64(statistics.blocks_in_use)
    )
}

private let sampleRates: [Double] = [44_100, 48_000, 96_000, 192_000]
private let frameCounts = [64, 128, 256, 512, 1_024, 2_048, 8_192]
private let modes: [EQRenderMode] = [.standardIIR, .hqFIR]

/// Twenty enabled stereo biquads at maximum Q and gain magnitude keep both
/// IIR channels fully populated and create a non-trivial FIR workload.
private func makeWorstCaseStereoPreset() -> EQPreset {
    let frequencies: [Double] = [
        25, 32, 40, 50, 63, 80, 100, 125, 160, 200,
        315, 500, 800, 1_250, 2_000, 3_150, 5_000, 8_000, 12_500, 19_000
    ]
    let bands = frequencies.enumerated().map { offset, frequency in
        EQBand(
            index: offset + 1,
            type: .bell,
            frequencyHz: frequency,
            gainDb: offset.isMultiple(of: 2) ? 18 : -18,
            q: 10,
            channel: .stereo,
            enabled: true
        )
    }
    let measuredPoints = (0..<127).map { index -> MeasuredCorrectionPoint in
        let frequency = 20 * pow(1_000, Double(index) / 126)
        let logFrequency = log2(frequency / 1_000)
        let bass = 4.5 / (1 + pow(frequency / 120, 3))
        let presenceDip = -2.5 * exp(-pow(logFrequency - 1.7, 2) / 0.45)
        let texture = 0.8 * sin(log(frequency) * 2.1)
        return MeasuredCorrectionPoint(
            frequencyHz: frequency,
            gainDb: bass + presenceDip + texture
        )
    }
    let measured = MeasuredCorrectionPayload(
        measurementId: "benchmark-measured",
        source: "benchmark fixture",
        provenanceURL: "https://example.invalid/benchmark-graphic-eq",
        sourcePreampDb: -24,
        contentHash: MeasuredCorrectionPayload.contentHash(points: measuredPoints),
        usableLowHz: 40,
        usableHighHz: 10_000,
        points: measuredPoints
    )
    return EQPreset(
        id: "benchmark_worst_case_stereo",
        name: "Benchmark Measured FIR + 20 preference bands",
        goal: "Exercise measured partitioned FIR and all twenty preference sections",
        preampDb: -24,
        bands: bands,
        correction: CorrectionMetadata(
            role: .combined,
            source: "benchmark fixture",
            sourceConfidence: .measured,
            preferenceBandIndexes: Array(1...20),
            measuredCorrection: measured
        )
    )
}

/// Deterministic broadband input. Input preparation is intentionally outside
/// the timed callback interval.
private func makeInput(frames: Int, sampleRate: Double) -> (left: [Float], right: [Float]) {
    var state: UInt64 = 0x4d595df4d0f33173
    func noise() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(UInt64(1) << 53)
        return unit * 2 - 1
    }

    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
        let time = Double(frame) / sampleRate
        let common = 0.006 * sin(2 * .pi * 997 * time)
            + 0.004 * sin(2 * .pi * 7_003 * time)
        left[frame] = Float(common + 0.002 * noise())
        right[frame] = Float(common - 0.002 * noise())
    }
    return (left, right)
}

private func refill(
    left: UnsafeMutablePointer<Float>,
    right: UnsafeMutablePointer<Float>,
    from input: (left: [Float], right: [Float]),
    frames: Int
) {
    input.left.withUnsafeBufferPointer { source in
        left.update(from: source.baseAddress!, count: frames)
    }
    input.right.withUnsafeBufferPointer { source in
        right.update(from: source.baseAddress!, count: frames)
    }
}

@inline(__always)
private func threadCPUTimeNanoseconds() -> UInt64 {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func nearestRankPercentile(_ sorted: [UInt64], percentile: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int(ceil(percentile * Double(sorted.count)))
    let index = min(max(rank - 1, 0), sorted.count - 1)
    return Double(sorted[index])
}

private func measure(
    mode: EQRenderMode,
    sampleRate: Double,
    frames: Int,
    iterations: Int,
    warmupIterations: Int,
    preset: EQPreset
) -> Measurement {
    let processor = EQProcessor(sampleRate: sampleRate, channelCount: 2)
    processor.update(preset: preset)
    let accepted = processor.setRenderMode(mode)
    precondition(accepted, "benchmark preset must support \(mode.rawValue)")
    processor.setClipProtectionEnabled(false)

    let input = makeInput(frames: frames, sampleRate: sampleRate)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer {
        left.deallocate()
        right.deallocate()
    }

    for _ in 0..<warmupIterations {
        refill(left: left, right: right, from: input, frames: frames)
        _ = processor.processInPlace(left: left, right: right, frames: frames)
    }

    var durations = [UInt64]()
    durations.reserveCapacity(iterations)
    var checksum = 0.0
    let heapBefore = heapSnapshot()
    for iteration in 0..<iterations {
        refill(left: left, right: right, from: input, frames: frames)

        let start = threadCPUTimeNanoseconds()
        let peak = processor.processInPlace(left: left, right: right, frames: frames)
        let end = threadCPUTimeNanoseconds()

        durations.append(end - start)
        let sampleIndex = iteration % frames
        checksum += Double(peak) + Double(left[sampleIndex]) + Double(right[sampleIndex])
    }
    let heapAfter = heapSnapshot()

    durations.sort()
    return Measurement(
        mode: mode,
        sampleRate: sampleRate,
        frames: frames,
        iterations: iterations,
        p50Nanoseconds: nearestRankPercentile(durations, percentile: 0.50),
        p99Nanoseconds: nearestRankPercentile(durations, percentile: 0.99),
        maxNanoseconds: Double(durations.last ?? 0),
        heapBytesDelta: Int64(heapAfter.bytesInUse) - Int64(heapBefore.bytesInUse),
        heapBlocksDelta: Int64(heapAfter.blocksInUse) - Int64(heapBefore.blocksInUse),
        checksum: checksum
    )
}

private func measureTransition(
    sampleRate: Double,
    frames: Int,
    preset: EQPreset
) -> TransitionMeasurement {
    let processor = EQProcessor(sampleRate: sampleRate, channelCount: 2)
    processor.update(preset: preset)
    precondition(processor.setRenderMode(.standardIIR))
    processor.setClipProtectionEnabled(false)
    let input = makeInput(frames: frames, sampleRate: sampleRate)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer {
        left.deallocate()
        right.deallocate()
    }
    for _ in 0..<10 {
        refill(left: left, right: right, from: input, frames: frames)
        _ = processor.processInPlace(left: left, right: right, frames: frames)
    }

    let callbacksPerDirection = max(8, Int(ceil(sampleRate * 0.08 / Double(frames))))
    var durations: [UInt64] = []
    durations.reserveCapacity(callbacksPerDirection * 2)
    precondition(processor.setRenderMode(.hqFIR))
    for _ in 0..<callbacksPerDirection {
        refill(left: left, right: right, from: input, frames: frames)
        let start = threadCPUTimeNanoseconds()
        _ = processor.processInPlace(left: left, right: right, frames: frames)
        durations.append(threadCPUTimeNanoseconds() - start)
    }
    precondition(processor.setRenderMode(.standardIIR))
    for _ in 0..<callbacksPerDirection {
        refill(left: left, right: right, from: input, frames: frames)
        let start = threadCPUTimeNanoseconds()
        _ = processor.processInPlace(left: left, right: right, frames: frames)
        durations.append(threadCPUTimeNanoseconds() - start)
    }
    durations.sort()
    return TransitionMeasurement(
        sampleRate: sampleRate,
        frames: frames,
        p99Nanoseconds: nearestRankPercentile(durations, percentile: 0.99),
        maxNanoseconds: Double(durations.last ?? 0)
    )
}

private func measureHQControlRamps(
    sampleRate: Double,
    frames: Int,
    preset: EQPreset
) -> TransitionMeasurement {
    let processor = EQProcessor(sampleRate: sampleRate, channelCount: 2)
    processor.update(preset: preset)
    precondition(processor.setRenderMode(.hqFIR))
    processor.setClipProtectionEnabled(false)
    let input = makeInput(frames: frames, sampleRate: sampleRate)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer {
        left.deallocate()
        right.deallocate()
    }
    let callbacksPerPhase = max(8, Int(ceil(sampleRate * 0.08 / Double(frames))))
    for _ in 0..<callbacksPerPhase {
        refill(left: left, right: right, from: input, frames: frames)
        _ = processor.processInPlace(left: left, right: right, frames: frames)
    }

    var durations: [UInt64] = []
    durations.reserveCapacity(callbacksPerPhase * 4)
    func measurePhase(_ controls: () -> Void) {
        controls()
        for _ in 0..<callbacksPerPhase {
            refill(left: left, right: right, from: input, frames: frames)
            let start = threadCPUTimeNanoseconds()
            _ = processor.processInPlace(left: left, right: right, frames: frames)
            durations.append(threadCPUTimeNanoseconds() - start)
        }
    }
    measurePhase { processor.setPreamp(-12) }
    measurePhase {
        processor.setPreamp(0)
        processor.setEnabled(false)
    }
    measurePhase {
        processor.setPreamp(-6)
        processor.setEnabled(true)
        precondition(processor.setRenderMode(.standardIIR))
    }
    measurePhase {
        processor.setPreamp(0)
        precondition(processor.setRenderMode(.hqFIR))
    }

    durations.sort()
    return TransitionMeasurement(
        sampleRate: sampleRate,
        frames: frames,
        p99Nanoseconds: nearestRankPercentile(durations, percentile: 0.99),
        maxNanoseconds: Double(durations.last ?? 0)
    )
}

private func sampleRateLabel(_ sampleRate: Double) -> String {
    sampleRate == 44_100 ? "44.1k" : String(format: "%.0fk", sampleRate / 1_000)
}

private func printHeader(configuration: Configuration) {
    print("Auralink Release DSP callback benchmark (\(configuration.label))")
    print("Preset: measured FIR baseline + 20 enabled preference bells, alternating +/-18 dB, Q 10")
    print("Timing: processInPlace thread CPU time; FIR design/setup, warmup, input refill, and scheduler preemption excluded")
    print("Iterations: IIR \(configuration.iirIterations), FIR \(configuration.firIterations) per case")
    print("Compute gate: p99 <= 25% and max < 100% of callback period (thread CPU; wall deadline is verified in live RT telemetry)")
    print("")
    print("Mode          Rate Frames     p50 us     p99 us     max us  Deadline us   p99/deadline   RT x(p99)   RT gate")
    print("------------ ----- ------ ---------- ---------- ---------- ------------ -------------- ----------- --------")
}

private func printMeasurement(_ result: Measurement) {
    let mode = result.mode == .standardIIR ? "standardIIR" : "hqFIR"
    let gate: String
    gate = result.realtimeGatePassed ? "PASS" : "FAIL"
    print(String(
        format: "%-12s %5s %6d %10.2f %10.2f %10.2f %12.2f %13.2f%% %11.2fx %8s",
        (mode as NSString).utf8String!,
        (sampleRateLabel(result.sampleRate) as NSString).utf8String!,
        result.frames,
        result.p50Nanoseconds / 1_000,
        result.p99Nanoseconds / 1_000,
        result.maxNanoseconds / 1_000,
        result.deadlineNanoseconds / 1_000,
        result.p99DeadlinePercent,
        result.p99RealtimeMultiplier,
        (gate as NSString).utf8String!
    ))
}

private let benchmarkActivity = ProcessInfo.processInfo.beginActivity(
    options: [.latencyCritical, .userInitiated],
    reason: "Auralink Release DSP callback benchmark"
)
_ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
defer { ProcessInfo.processInfo.endActivity(benchmarkActivity) }

private let configuration = Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
private let preset = makeWorstCaseStereoPreset()
private var results: [Measurement] = []
private var transitionResults: [TransitionMeasurement] = []
private var controlRampResults: [TransitionMeasurement] = []

printHeader(configuration: configuration)
for mode in modes {
    let iterations = mode == .standardIIR
        ? configuration.iirIterations
        : configuration.firIterations
    for sampleRate in sampleRates {
        for frames in frameCounts {
            let result = measure(
                mode: mode,
                sampleRate: sampleRate,
                frames: frames,
                iterations: iterations,
                warmupIterations: configuration.warmupIterations,
                preset: preset
            )
            results.append(result)
            printMeasurement(result)
        }
    }
}

let passCount = results.filter(\.realtimeGatePassed).count
let failureCount = results.count - passCount
let checksum = results.reduce(0.0) { $0 + $1.checksum }
private let heapGrowthCases = results.filter { $0.heapBytesDelta > 0 || $0.heapBlocksDelta > 0 }
print("")
print("Steady compute-budget gate summary: \(passCount)/\(results.count) PASS, \(failureCount) FAIL")
if heapGrowthCases.isEmpty {
    print("Steady-state heap-retention gate: PASS (no net bytes/blocks retained; this is not an allocation-event counter)")
} else {
    let maxBytes = heapGrowthCases.map(\.heapBytesDelta).max() ?? 0
    let maxBlocks = heapGrowthCases.map(\.heapBlocksDelta).max() ?? 0
    print("Steady-state heap-retention gate: WARN (\(heapGrowthCases.count) cases; max +\(maxBytes) bytes, +\(maxBlocks) blocks)")
}
print(String(format: "Run checksum: %.9e", checksum))

print("")
print("Measured FIR IIR↔FIR transition compute gate (p99 <= 50%, max < callback period)")
print("Rate Frames     p99 us     max us  Deadline us   p99/deadline  Gate")
print("---- ------ ---------- ---------- ------------ -------------- -----")
for sampleRate in sampleRates {
    for frames in frameCounts {
        let result = measureTransition(sampleRate: sampleRate, frames: frames, preset: preset)
        transitionResults.append(result)
        print(String(
            format: "%4s %6d %10.2f %10.2f %12.2f %13.2f%% %5s",
            (sampleRateLabel(sampleRate) as NSString).utf8String!,
            frames,
            result.p99Nanoseconds / 1_000,
            result.maxNanoseconds / 1_000,
            result.deadlineNanoseconds / 1_000,
            result.p99DeadlinePercent,
            ((result.gatePassed ? "PASS" : "FAIL") as NSString).utf8String!
        ))
    }
}
let transitionPassCount = transitionResults.filter(\.gatePassed).count
let transitionFailureCount = transitionResults.count - transitionPassCount
print("Transition compute-gate summary: \(transitionPassCount)/\(transitionResults.count) PASS, \(transitionFailureCount) FAIL")

print("")
print("Measured FIR preamp/bypass/combined-control compute gate (p99 <= 50%, max < callback period)")
for sampleRate in sampleRates {
    for frames in frameCounts {
        let result = measureHQControlRamps(sampleRate: sampleRate, frames: frames, preset: preset)
        controlRampResults.append(result)
        if !result.gatePassed {
            print(String(
                format: "FAIL %4s %6d: p99 %.2f%%, max %.2f us / %.2f us deadline",
                (sampleRateLabel(sampleRate) as NSString).utf8String!,
                frames,
                result.p99DeadlinePercent,
                result.maxNanoseconds / 1_000,
                result.deadlineNanoseconds / 1_000
            ))
        }
    }
}
let controlRampPassCount = controlRampResults.filter(\.gatePassed).count
let controlRampFailureCount = controlRampResults.count - controlRampPassCount
print("Control-ramp compute-gate summary: \(controlRampPassCount)/\(controlRampResults.count) PASS, \(controlRampFailureCount) FAIL")
if let worstControlRamp = controlRampResults.max(by: { $0.p99DeadlinePercent < $1.p99DeadlinePercent }) {
    print(String(
        format: "Worst control ramp: %4s/%d frames p99 %.2f%% of callback period, max %.2f us",
        (sampleRateLabel(worstControlRamp.sampleRate) as NSString).utf8String!,
        worstControlRamp.frames,
        worstControlRamp.p99DeadlinePercent,
        worstControlRamp.maxNanoseconds / 1_000
    ))
}
print("")
print("Cold measured-FIR preparation wall-time gate (<= 250 ms)")
var preparationFailureCount = 0
for sampleRate in sampleRates {
    let processor = EQProcessor(sampleRate: sampleRate, channelCount: 2)
    processor.update(preset: preset)
    let start = DispatchTime.now().uptimeNanoseconds
    let accepted = processor.setRenderMode(.hqFIR)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    let passed = accepted && elapsedMs <= 250
    if !passed { preparationFailureCount += 1 }
    print(String(
        format: "%4s: %7.2f ms  %s",
        (sampleRateLabel(sampleRate) as NSString).utf8String!,
        elapsedMs,
        ((passed ? "PASS" : "FAIL") as NSString).utf8String!
    ))
}
print("Preparation gate summary: \(sampleRates.count - preparationFailureCount)/\(sampleRates.count) PASS, \(preparationFailureCount) FAIL")

if failureCount > 0
    || transitionFailureCount > 0
    || controlRampFailureCount > 0
    || preparationFailureCount > 0
    || !heapGrowthCases.isEmpty {
    exit(1)
}
