#ifndef AURALINK_RT_H
#define AURALINK_RT_H

#include <stdint.h>
#include <stdbool.h>

/// Realtime-safe primitives for the audio path, implemented in C so the render
/// thread never touches a Swift lock, allocation, or runtime call:
///
///  - `alk_ring`     a lock-free single-producer / single-consumer planar
///                   stereo float ring buffer (capture tap -> render block).
///  - `alk_rt_state` a bundle of atomic meters/counters the audio threads
///                   update and the telemetry timer drains.
///
/// Memory ordering follows the classic SPSC pattern: the producer publishes
/// data with a release store of `head`; the consumer publishes free space with
/// a release store of `tail`; each side acquire-loads the other's index.

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Lock-free SPSC stereo ring

typedef struct alk_ring alk_ring;

/// Creates a ring holding `capacity_frames` stereo frames. Returns NULL on
/// allocation failure. Not realtime-safe (allocates); call from control code.
alk_ring *alk_ring_create(uint32_t capacity_frames);
void alk_ring_destroy(alk_ring *ring);

/// Resets indices and zeroes storage. ONLY safe while neither audio thread is
/// touching the ring (engine stopped).
void alk_ring_reset(alk_ring *ring);

/// Frames currently available to read / write. Realtime-safe.
uint32_t alk_ring_readable(const alk_ring *ring);
uint32_t alk_ring_writable(const alk_ring *ring);

/// Producer: append planar L/R frames. Writes at most `alk_ring_writable()`
/// frames (incoming overflow is dropped — the producer never moves the
/// consumer's index). Returns frames written. `right` may equal `left`.
uint32_t alk_ring_write_planar(alk_ring *ring,
                               const float *left,
                               const float *right,
                               uint32_t frames);

/// Producer: append interleaved frames (channel 0 -> L, channel 1 -> R; mono
/// is duplicated to both). Returns frames written.
uint32_t alk_ring_write_interleaved(alk_ring *ring,
                                    const float *src,
                                    uint32_t channels,
                                    uint32_t frames);

/// Consumer: copy up to `frames` into planar dst buffers. Returns frames read.
uint32_t alk_ring_read(alk_ring *ring, float *left, float *right, uint32_t frames);

/// Consumer: discard up to `frames` without copying (drift servo). Returns
/// frames dropped.
uint32_t alk_ring_drop(alk_ring *ring, uint32_t frames);

// MARK: - Lock-free SPSC opaque-pointer retirement queue

typedef struct alk_ptr_queue alk_ptr_queue;

/// Fixed-capacity queue used to transfer retained Swift DSP objects from the
/// realtime render thread to a non-realtime control thread for destruction.
/// The queue never owns/releases the pointed-to objects itself.
alk_ptr_queue *alk_ptr_queue_create(uint32_t capacity);
void alk_ptr_queue_destroy(alk_ptr_queue *queue);
bool alk_ptr_queue_push(alk_ptr_queue *queue, void *pointer);  // producer / RT
void *alk_ptr_queue_pop(alk_ptr_queue *queue);                 // consumer / control

// MARK: - Atomic meters / counters

typedef struct alk_rt_state alk_rt_state;

/// One drained snapshot of the counters (values since the previous drain).
typedef struct {
    float    out_peak;
    float    pre_clip_peak;
    float    pre_clip_true_peak;
    float    true_peak;
    float    cap_peak;
    bool     clipped;
    uint64_t clip_events;
    uint64_t capture_callbacks;
    uint64_t captured_frames;
    uint64_t render_callbacks;
    uint64_t rendered_frames;
    uint64_t ring_read_frames;
    uint64_t underruns;
    uint64_t resyncs;
    uint64_t capture_gaps;
    uint32_t max_capture_gap_us;
    uint32_t last_buffer_frames;
    uint32_t active_render_mode;  // 0 = standard_iir, 1 = hq_fir
    uint64_t active_render_generation;
} alk_stats;

alk_rt_state *alk_state_create(void);
void alk_state_destroy(alk_rt_state *state);

/// `running` gates the realtime paths; `primed` tracks whether the ring has
/// reached its target fill since the last (re)start or underrun.
void alk_state_set_running(alk_rt_state *state, bool running);
bool alk_state_running(const alk_rt_state *state);
void alk_state_set_primed(alk_rt_state *state, bool primed);
bool alk_state_primed(const alk_rt_state *state);

/// Producer-side bookkeeping: one capture callback of `frames` with `peak`.
void alk_state_note_capture(alk_rt_state *state, uint64_t frames, float peak);
/// Consumer-side bookkeeping: one render callback asking for `buffer_frames`.
void alk_state_note_render(alk_rt_state *state, uint32_t buffer_frames);
void alk_state_note_ring_read(alk_rt_state *state, uint64_t frames);
void alk_state_note_output(alk_rt_state *state,
                           float peak,
                           float pre_clip_peak,
                           float pre_clip_true_peak,
                           float true_peak,
                           bool clipped);
void alk_state_note_underrun(alk_rt_state *state);
/// Consumer-side bookkeeping: one faded latency resync (fill grew past twice
/// the target and the read position was jumped back).
void alk_state_note_resync(alk_rt_state *state);
/// Producer-side bookkeeping: the capture callback cadence skipped a beat —
/// the device missed (at least) one I/O cycle, so that audio is simply gone
/// from the stream. Small enough to leave the ring healthy, but audible.
void alk_state_note_capture_gap(alk_rt_state *state, uint32_t gap_us);
/// Render-thread committed mode. Unlike control intent, this changes only after
/// EQProcessor installs a prepared state at a real callback boundary.
void alk_state_set_active_render_mode(alk_rt_state *state, uint32_t mode);
uint32_t alk_state_active_render_mode(const alk_rt_state *state);
void alk_state_set_active_render_generation(alk_rt_state *state, uint64_t generation);
uint64_t alk_state_active_render_generation(const alk_rt_state *state);

/// Atomically takes-and-resets the counters/peaks (running/primed and
/// last_buffer_frames are read but left in place).
alk_stats alk_state_drain(alk_rt_state *state);

/// Non-draining read of the most recent render buffer size.
uint32_t alk_state_last_buffer_frames(const alk_rt_state *state);

/// Largest capture chunk / render quantum observed since the last
/// `alk_state_reset_quanta`. The render thread sizes the ring's target fill
/// from these, so the cushion adapts to whatever I/O granularity the devices
/// actually use instead of assuming one.
uint32_t alk_state_max_capture_frames(const alk_rt_state *state);
uint32_t alk_state_max_render_frames(const alk_rt_state *state);
void alk_state_reset_quanta(alk_rt_state *state);

#ifdef __cplusplus
}
#endif

#endif /* AURALINK_RT_H */
