import Accelerate
import Foundation

/// Zero-added-latency convolution: a short direct head produces the immediate
/// response while a frequency-domain delay line computes the remaining tail one
/// partition ahead. All setup and storage are allocated in `init`; render calls
/// accept arbitrary callback segmentation without allocation or blocking.
/// Mutable history is owned by exactly one render thread; this type is
/// intentionally not `Sendable` and provides no internal locking.
public final class PartitionedFIRConvolver {
    public let taps: [Float]
    public let partitionSize: Int
    public let fftSize: Int
    public let tailPartitionCount: Int
    public let algorithmicLatencyFrames = 0

    private var headConvolver: FIRConvolver
    private var dryScratch: [Float]

    private var inputBlock: [Float]
    private var inputIndex = 0
    private var tailOutput: [Float]
    private var overlap: [Float]

    private let log2FFT: vDSP_Length
    private let fftSetup: FFTSetup?
    private var historyReal: [[Float]]
    private var historyImaginary: [[Float]]
    private var historyIndex = -1
    private var kernelReal: [[Float]]
    private var kernelImaginary: [[Float]]
    private var workReal: [Float]
    private var workImaginary: [Float]
    private var accumulatedReal: [Float]
    private var accumulatedImaginary: [Float]

    public init(taps inputTaps: [Float] = [1], partitionSize requestedPartitionSize: Int = 128) {
        let clean = Self.sanitized(inputTaps)
        let partition = Self.nextPowerOfTwo(max(8, requestedPartitionSize))
        let transformSize = partition * 2
        let transformLog2 = vDSP_Length(Int(log2(Double(transformSize))))
        let proposedTailCount = clean.count > partition
            ? (clean.count - partition + partition - 1) / partition
            : 0
        let setup = proposedTailCount > 0
            ? vDSP_create_fftsetup(transformLog2, FFTRadix(kFFTRadix2))
            : nil
        let usableTailCount = setup == nil ? 0 : proposedTailCount
        let headCount = usableTailCount == 0 ? clean.count : min(partition, clean.count)

        self.taps = clean
        self.partitionSize = partition
        self.fftSize = transformSize
        self.log2FFT = transformLog2
        self.fftSetup = setup
        self.tailPartitionCount = usableTailCount
        self.headConvolver = FIRConvolver(
            taps: Array(clean.prefix(headCount)),
            maxFrames: 8_192
        )
        self.dryScratch = [Float](repeating: 0, count: 8_192)
        self.inputBlock = [Float](repeating: 0, count: partition)
        self.tailOutput = [Float](repeating: 0, count: partition)
        self.overlap = [Float](repeating: 0, count: partition)
        // Build every nested buffer independently. `Array(repeating:)` would
        // share CoW storage and force first-touch allocations on the RT thread.
        self.historyReal = (0..<usableTailCount).map { _ in
            [Float](repeating: 0, count: transformSize)
        }
        self.historyImaginary = (0..<usableTailCount).map { _ in
            [Float](repeating: 0, count: transformSize)
        }
        self.kernelReal = (0..<usableTailCount).map { _ in
            [Float](repeating: 0, count: transformSize)
        }
        self.kernelImaginary = (0..<usableTailCount).map { _ in
            [Float](repeating: 0, count: transformSize)
        }
        self.workReal = [Float](repeating: 0, count: transformSize)
        self.workImaginary = [Float](repeating: 0, count: transformSize)
        self.accumulatedReal = [Float](repeating: 0, count: transformSize)
        self.accumulatedImaginary = [Float](repeating: 0, count: transformSize)

        prepareTailKernels(clean)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    public var isIdentity: Bool {
        taps.count == 1 && abs(taps[0] - 1) < 1e-7
    }

    public func reset() {
        headConvolver.reset()
        dryScratch.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        inputBlock.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        tailOutput.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        overlap.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        for index in historyReal.indices {
            historyReal[index].withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            historyImaginary[index].withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        }
        inputIndex = 0
        historyIndex = -1
    }

    @inline(__always)
    public func process(_ input: Float) -> Float {
        let output = headConvolver.process(input) + processTail(input)
        return output.isFinite ? output : 0
    }

    public func processInPlace(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var offset = 0
        while offset < frames {
            let count = min(dryScratch.count, frames - offset)
            let block = buffer.advanced(by: offset)
            dryScratch.withUnsafeMutableBufferPointer { scratchPointer in
                guard let scratch = scratchPointer.baseAddress else { return }
                scratch.update(from: block, count: count)
                headConvolver.processInPlace(block, frames: count)
                for index in 0..<count {
                    let output = block[index] + processTail(scratch[index])
                    block[index] = output.isFinite ? output : 0
                }
            }
            offset += count
        }
    }

    @inline(__always)
    private func processTail(_ input: Float) -> Float {
        let output = tailOutput[inputIndex]
        inputBlock[inputIndex] = input
        inputIndex += 1
        if inputIndex == partitionSize {
            processTailBlock()
            inputIndex = 0
        }
        return output
    }

    private func prepareTailKernels(_ clean: [Float]) {
        guard tailPartitionCount > 0, let fftSetup else { return }
        for partitionIndex in 0..<tailPartitionCount {
            workReal.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            workImaginary.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            let sourceStart = partitionSize + partitionIndex * partitionSize
            let sourceEnd = min(sourceStart + partitionSize, clean.count)
            if sourceStart < sourceEnd {
                for sourceIndex in sourceStart..<sourceEnd {
                    workReal[sourceIndex - sourceStart] = clean[sourceIndex]
                }
            }
            transform(
                setup: fftSetup,
                real: &workReal,
                imaginary: &workImaginary,
                direction: FFTDirection(FFT_FORWARD)
            )
            copy(workReal, into: &kernelReal[partitionIndex])
            copy(workImaginary, into: &kernelImaginary[partitionIndex])
        }
        workReal.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        workImaginary.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        // Warm the inverse transform during setup so its first use is never in
        // the render callback.
        transform(
            setup: fftSetup,
            real: &workReal,
            imaginary: &workImaginary,
            direction: FFTDirection(FFT_INVERSE)
        )
        workReal.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        workImaginary.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
    }

    private func processTailBlock() {
        guard tailPartitionCount > 0, let fftSetup else { return }
        historyIndex = (historyIndex + 1) % tailPartitionCount
        workReal.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        workImaginary.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        for index in 0..<partitionSize { workReal[index] = inputBlock[index] }
        transform(
            setup: fftSetup,
            real: &workReal,
            imaginary: &workImaginary,
            direction: FFTDirection(FFT_FORWARD)
        )
        copy(workReal, into: &historyReal[historyIndex])
        copy(workImaginary, into: &historyImaginary[historyIndex])

        accumulatedReal.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        accumulatedImaginary.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        for partitionIndex in 0..<tailPartitionCount {
            var slot = historyIndex - partitionIndex
            if slot < 0 { slot += tailPartitionCount }
            accumulateProduct(historySlot: slot, kernelIndex: partitionIndex)
        }
        transform(
            setup: fftSetup,
            real: &accumulatedReal,
            imaginary: &accumulatedImaginary,
            direction: FFTDirection(FFT_INVERSE)
        )
        let scale = Float(1.0 / Double(fftSize))
        for index in 0..<partitionSize {
            tailOutput[index] = accumulatedReal[index] * scale + overlap[index]
            overlap[index] = accumulatedReal[index + partitionSize] * scale
        }
    }

    private func accumulateProduct(historySlot: Int, kernelIndex: Int) {
        let count = vDSP_Length(fftSize)
        historyReal[historySlot].withUnsafeMutableBufferPointer { historyRealPointer in
            historyImaginary[historySlot].withUnsafeMutableBufferPointer { historyImaginaryPointer in
                kernelReal[kernelIndex].withUnsafeMutableBufferPointer { kernelRealPointer in
                    kernelImaginary[kernelIndex].withUnsafeMutableBufferPointer { kernelImaginaryPointer in
                        workReal.withUnsafeMutableBufferPointer { productRealPointer in
                            workImaginary.withUnsafeMutableBufferPointer { productImaginaryPointer in
                                guard let historyRealBase = historyRealPointer.baseAddress,
                                      let historyImaginaryBase = historyImaginaryPointer.baseAddress,
                                      let kernelRealBase = kernelRealPointer.baseAddress,
                                      let kernelImaginaryBase = kernelImaginaryPointer.baseAddress,
                                      let productRealBase = productRealPointer.baseAddress,
                                      let productImaginaryBase = productImaginaryPointer.baseAddress else { return }
                                var input = DSPSplitComplex(
                                    realp: historyRealBase,
                                    imagp: historyImaginaryBase
                                )
                                var filter = DSPSplitComplex(
                                    realp: kernelRealBase,
                                    imagp: kernelImaginaryBase
                                )
                                var product = DSPSplitComplex(
                                    realp: productRealBase,
                                    imagp: productImaginaryBase
                                )
                                vDSP_zvmul(&input, 1, &filter, 1, &product, 1, count, 1)
                            }
                        }
                    }
                }
            }
        }
        workReal.withUnsafeBufferPointer { productPointer in
            accumulatedReal.withUnsafeMutableBufferPointer { accumulatedPointer in
                guard let productBase = productPointer.baseAddress,
                      let accumulatedBase = accumulatedPointer.baseAddress else { return }
                vDSP_vadd(productBase, 1, accumulatedBase, 1, accumulatedBase, 1, count)
            }
        }
        workImaginary.withUnsafeBufferPointer { productPointer in
            accumulatedImaginary.withUnsafeMutableBufferPointer { accumulatedPointer in
                guard let productBase = productPointer.baseAddress,
                      let accumulatedBase = accumulatedPointer.baseAddress else { return }
                vDSP_vadd(productBase, 1, accumulatedBase, 1, accumulatedBase, 1, count)
            }
        }
    }

    private func transform(
        setup: FFTSetup,
        real: inout [Float],
        imaginary: inout [Float],
        direction: FFTDirection
    ) {
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let realBase = realPointer.baseAddress,
                      let imaginaryBase = imaginaryPointer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                vDSP_fft_zip(setup, &split, 1, log2FFT, direction)
            }
        }
    }

    private func copy(_ source: [Float], into destination: inout [Float]) {
        let count = min(source.count, destination.count)
        source.withUnsafeBufferPointer { sourcePointer in
            destination.withUnsafeMutableBufferPointer { destinationPointer in
                guard let sourceBase = sourcePointer.baseAddress,
                      let destinationBase = destinationPointer.baseAddress else { return }
                destinationBase.update(from: sourceBase, count: count)
            }
        }
    }

    private static func sanitized(_ taps: [Float]) -> [Float] {
        let finite = taps.map { $0.isFinite ? $0 : 0 }
        if finite.isEmpty { return [1] }
        if finite.allSatisfy({ abs($0) < 1e-12 }) { return [0] }
        return finite
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }
}
