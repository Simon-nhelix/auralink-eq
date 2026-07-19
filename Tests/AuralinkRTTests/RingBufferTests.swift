import XCTest
import AuralinkRT

/// Exercises the C lock-free SPSC ring from a single thread (correctness of
/// indices, wraparound, and overflow policy) plus a producer/consumer stress
/// pass. Realtime properties (no locks/allocations) are by construction in C.
final class RingBufferTests: XCTestCase {

    private func makeRing(_ capacity: UInt32) -> OpaquePointer {
        let ring = alk_ring_create(capacity)
        XCTAssertNotNil(ring)
        return ring!
    }

    func testWriteReadRoundtrip() {
        let ring = makeRing(16)
        defer { alk_ring_destroy(ring) }

        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [5, 6, 7, 8]
        XCTAssertEqual(alk_ring_write_planar(ring, left, right, 4), 4)
        XCTAssertEqual(alk_ring_readable(ring), 4)

        var outL = [Float](repeating: 0, count: 4)
        var outR = [Float](repeating: 0, count: 4)
        let got = outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                alk_ring_read(ring, lp.baseAddress, rp.baseAddress, 4)
            }
        }
        XCTAssertEqual(got, 4)
        XCTAssertEqual(outL, left)
        XCTAssertEqual(outR, right)
        XCTAssertEqual(alk_ring_readable(ring), 0)
    }

    func testWraparoundPreservesOrder() {
        let ring = makeRing(8)
        defer { alk_ring_destroy(ring) }

        var outL = [Float](repeating: 0, count: 8)
        var outR = [Float](repeating: 0, count: 8)

        // Repeatedly write 5 / read 5 so the indices wrap several times.
        var next: Float = 0
        for _ in 0..<10 {
            let l = (0..<5).map { next + Float($0) }
            let r = l.map { $0 + 1000 }
            XCTAssertEqual(alk_ring_write_planar(ring, l, r, 5), 5)
            let got = outL.withUnsafeMutableBufferPointer { lp in
                outR.withUnsafeMutableBufferPointer { rp in
                    alk_ring_read(ring, lp.baseAddress, rp.baseAddress, 5)
                }
            }
            XCTAssertEqual(got, 5)
            XCTAssertEqual(Array(outL.prefix(5)), l)
            XCTAssertEqual(Array(outR.prefix(5)), r)
            next += 5
        }
    }

    func testOverflowDropsIncomingNotBuffered() {
        let ring = makeRing(4)
        defer { alk_ring_destroy(ring) }

        let l: [Float] = [1, 2, 3, 4, 5, 6]
        let r: [Float] = [1, 2, 3, 4, 5, 6]
        // Capacity 4 ⇒ only 4 of the 6 incoming frames fit.
        XCTAssertEqual(alk_ring_write_planar(ring, l, r, 6), 4)
        XCTAssertEqual(alk_ring_readable(ring), 4)
        XCTAssertEqual(alk_ring_writable(ring), 0)

        var outL = [Float](repeating: 0, count: 4)
        var outR = [Float](repeating: 0, count: 4)
        _ = outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                alk_ring_read(ring, lp.baseAddress, rp.baseAddress, 4)
            }
        }
        // The *oldest* data survives; the overflow tail was dropped.
        XCTAssertEqual(outL, [1, 2, 3, 4])
    }

    func testInterleavedStereoAndMono() {
        let ring = makeRing(16)
        defer { alk_ring_destroy(ring) }

        // Stereo interleaved: L0 R0 L1 R1 …
        let stereo: [Float] = [1, -1, 2, -2, 3, -3]
        XCTAssertEqual(alk_ring_write_interleaved(ring, stereo, 2, 3), 3)

        // Mono: duplicated into both channels.
        let mono: [Float] = [9, 8]
        XCTAssertEqual(alk_ring_write_interleaved(ring, mono, 1, 2), 2)

        var outL = [Float](repeating: 0, count: 5)
        var outR = [Float](repeating: 0, count: 5)
        let got = outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                alk_ring_read(ring, lp.baseAddress, rp.baseAddress, 5)
            }
        }
        XCTAssertEqual(got, 5)
        XCTAssertEqual(outL, [1, 2, 3, 9, 8])
        XCTAssertEqual(outR, [-1, -2, -3, 9, 8])
    }

    func testDropAdvancesTail() {
        let ring = makeRing(16)
        defer { alk_ring_destroy(ring) }

        let data: [Float] = [1, 2, 3, 4, 5]
        _ = alk_ring_write_planar(ring, data, data, 5)
        XCTAssertEqual(alk_ring_drop(ring, 2), 2)
        XCTAssertEqual(alk_ring_readable(ring), 3)

        var outL = [Float](repeating: 0, count: 3)
        var outR = [Float](repeating: 0, count: 3)
        _ = outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                alk_ring_read(ring, lp.baseAddress, rp.baseAddress, 3)
            }
        }
        XCTAssertEqual(outL, [3, 4, 5])
        // Dropping more than available drops only what exists.
        XCTAssertEqual(alk_ring_drop(ring, 10), 0)
    }

    func testConcurrentProducerConsumerIntegrity() {
        let ring = makeRing(1024)
        defer { alk_ring_destroy(ring) }

        let totalFrames = 200_000
        let chunk = 313  // deliberately not a divisor of the capacity

        let producer = Thread {
            var sent = 0
            var l = [Float](repeating: 0, count: chunk)
            var r = [Float](repeating: 0, count: chunk)
            while sent < totalFrames {
                let n = min(chunk, totalFrames - sent)
                for i in 0..<n {
                    l[i] = Float(sent + i)
                    r[i] = -Float(sent + i)
                }
                var offset = 0
                while offset < n {
                    let wrote = l.withUnsafeBufferPointer { lp in
                        r.withUnsafeBufferPointer { rp in
                            alk_ring_write_planar(
                                ring,
                                lp.baseAddress! + offset,
                                rp.baseAddress! + offset,
                                UInt32(n - offset)
                            )
                        }
                    }
                    offset += Int(wrote)
                    if wrote == 0 { usleep(50) }
                }
                sent += n
            }
        }

        var received = 0
        var corrupt = false
        producer.start()

        var outL = [Float](repeating: 0, count: 512)
        var outR = [Float](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(15)
        while received < totalFrames && Date() < deadline {
            let got = outL.withUnsafeMutableBufferPointer { lp in
                outR.withUnsafeMutableBufferPointer { rp in
                    alk_ring_read(ring, lp.baseAddress, rp.baseAddress, 512)
                }
            }
            if got == 0 {
                usleep(50)
                continue
            }
            for i in 0..<Int(got) {
                if outL[i] != Float(received + i) || outR[i] != -Float(received + i) {
                    corrupt = true
                    break
                }
            }
            if corrupt { break }
            received += Int(got)
        }

        XCTAssertFalse(corrupt, "ring delivered out-of-order or corrupted frames")
        XCTAssertEqual(received, totalFrames, "consumer did not receive every frame")
    }

    func testOpaquePointerQueuePreservesFIFOAndCapacity() {
        let queue = alk_ptr_queue_create(2)
        XCTAssertNotNil(queue)
        defer { alk_ptr_queue_destroy(queue) }
        let first = UnsafeMutableRawPointer(bitPattern: 0x10)
        let second = UnsafeMutableRawPointer(bitPattern: 0x20)
        let third = UnsafeMutableRawPointer(bitPattern: 0x30)
        XCTAssertTrue(alk_ptr_queue_push(queue, first))
        XCTAssertTrue(alk_ptr_queue_push(queue, second))
        XCTAssertFalse(alk_ptr_queue_push(queue, third))
        XCTAssertEqual(alk_ptr_queue_pop(queue), first)
        XCTAssertTrue(alk_ptr_queue_push(queue, third))
        XCTAssertEqual(alk_ptr_queue_pop(queue), second)
        XCTAssertEqual(alk_ptr_queue_pop(queue), third)
        XCTAssertNil(alk_ptr_queue_pop(queue))
    }

    func testStateDrainResetsCounters() {
        let state = alk_state_create()
        defer { alk_state_destroy(state) }

        alk_state_note_capture(state!, 1024, 0.5)
        alk_state_note_capture(state!, 1024, 0.25)   // lower peak must not win
        alk_state_note_render(state!, 512)
        alk_state_note_ring_read(state!, 512)
        alk_state_note_output(state!, 0.9, 0.95, 0.99, 0.98, false)
        alk_state_note_output(state!, 1.0, 1.25, 1.32, 1.08, true)
        alk_state_note_underrun(state!)
        alk_state_note_resync(state!)
        alk_state_note_capture_gap(state!, 5_300)
        alk_state_note_capture_gap(state!, 2_100)   // smaller gap must not win the max
        alk_state_set_active_render_mode(state!, 1)
        alk_state_set_active_render_generation(state!, 42)

        var stats = alk_state_drain(state!)
        XCTAssertEqual(stats.capture_callbacks, 2)
        XCTAssertEqual(stats.captured_frames, 2048)
        XCTAssertEqual(stats.render_callbacks, 1)
        XCTAssertEqual(stats.rendered_frames, 512)
        XCTAssertEqual(stats.ring_read_frames, 512)
        XCTAssertEqual(stats.underruns, 1)
        XCTAssertEqual(stats.resyncs, 1)
        XCTAssertEqual(stats.capture_gaps, 2)
        XCTAssertEqual(stats.max_capture_gap_us, 5_300)
        XCTAssertEqual(stats.cap_peak, 0.5)
        XCTAssertEqual(stats.out_peak, 1.0)
        XCTAssertEqual(stats.pre_clip_peak, 1.25)
        XCTAssertEqual(stats.pre_clip_true_peak, 1.32, accuracy: 1e-6)
        XCTAssertEqual(stats.true_peak, 1.08, accuracy: 1e-6)
        XCTAssertTrue(stats.clipped)
        XCTAssertEqual(stats.clip_events, 1)
        XCTAssertEqual(stats.last_buffer_frames, 512)
        XCTAssertEqual(stats.active_render_mode, 1)
        XCTAssertEqual(alk_state_active_render_mode(state!), 1)
        XCTAssertEqual(stats.active_render_generation, 42)
        XCTAssertEqual(alk_state_active_render_generation(state!), 42)

        // Second drain: counters reset; sticky state fields remain.
        stats = alk_state_drain(state!)
        XCTAssertEqual(stats.capture_callbacks, 0)
        XCTAssertEqual(stats.resyncs, 0)
        XCTAssertEqual(stats.capture_gaps, 0)
        XCTAssertEqual(stats.max_capture_gap_us, 0)
        XCTAssertEqual(stats.out_peak, 0)
        XCTAssertEqual(stats.pre_clip_peak, 0)
        XCTAssertEqual(stats.pre_clip_true_peak, 0)
        XCTAssertEqual(stats.true_peak, 0)
        XCTAssertFalse(stats.clipped)
        XCTAssertEqual(stats.clip_events, 0)
        XCTAssertEqual(stats.last_buffer_frames, 512)
        XCTAssertEqual(stats.active_render_mode, 1)
        XCTAssertEqual(stats.active_render_generation, 42)
    }

    func testMaxQuantaTrackAndReset() {
        let state = alk_state_create()
        defer { alk_state_destroy(state) }

        // Max trackers keep the largest observed chunk/quantum, survive drains,
        // and reset only via alk_state_reset_quanta (called on engine start).
        alk_state_note_capture(state!, 512, 0.1)
        alk_state_note_capture(state!, 19_200, 0.1)
        alk_state_note_capture(state!, 1_024, 0.1)
        alk_state_note_render(state!, 512)
        alk_state_note_render(state!, 4_096)
        alk_state_note_render(state!, 256)

        XCTAssertEqual(alk_state_max_capture_frames(state!), 19_200)
        XCTAssertEqual(alk_state_max_render_frames(state!), 4_096)
        _ = alk_state_drain(state!)
        XCTAssertEqual(alk_state_max_capture_frames(state!), 19_200, "drain must not reset quanta")

        alk_state_reset_quanta(state!)
        XCTAssertEqual(alk_state_max_capture_frames(state!), 0)
        XCTAssertEqual(alk_state_max_render_frames(state!), 0)
    }
}
