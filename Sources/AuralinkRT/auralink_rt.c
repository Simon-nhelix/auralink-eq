#include "auralink_rt.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// MARK: - Ring

struct alk_ring {
    float *left;
    float *right;
    /// Slot count = capacity_frames + 1; one slot stays empty so head == tail
    /// unambiguously means "empty".
    uint32_t slots;
    _Atomic uint32_t head;  // producer-owned write index
    _Atomic uint32_t tail;  // consumer-owned read index
};

alk_ring *alk_ring_create(uint32_t capacity_frames) {
    if (capacity_frames < 2) capacity_frames = 2;
    alk_ring *r = calloc(1, sizeof(alk_ring));
    if (!r) return NULL;
    r->slots = capacity_frames + 1;
    r->left = calloc(r->slots, sizeof(float));
    r->right = calloc(r->slots, sizeof(float));
    if (!r->left || !r->right) {
        alk_ring_destroy(r);
        return NULL;
    }
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    return r;
}

void alk_ring_destroy(alk_ring *r) {
    if (!r) return;
    free(r->left);
    free(r->right);
    free(r);
}

void alk_ring_reset(alk_ring *r) {
    if (!r) return;
    atomic_store_explicit(&r->head, 0, memory_order_relaxed);
    atomic_store_explicit(&r->tail, 0, memory_order_relaxed);
    memset(r->left, 0, r->slots * sizeof(float));
    memset(r->right, 0, r->slots * sizeof(float));
}

static inline uint32_t ring_readable(uint32_t head, uint32_t tail, uint32_t slots) {
    return (head + slots - tail) % slots;
}

uint32_t alk_ring_readable(const alk_ring *r) {
    uint32_t head = atomic_load_explicit((_Atomic uint32_t *)&r->head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit((_Atomic uint32_t *)&r->tail, memory_order_acquire);
    return ring_readable(head, tail, r->slots);
}

uint32_t alk_ring_writable(const alk_ring *r) {
    return (r->slots - 1) - alk_ring_readable(r);
}

uint32_t alk_ring_write_planar(alk_ring *r,
                               const float *left,
                               const float *right,
                               uint32_t frames) {
    uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    uint32_t writable = (r->slots - 1) - ring_readable(head, tail, r->slots);
    uint32_t n = frames < writable ? frames : writable;
    if (n == 0) return 0;

    uint32_t first = r->slots - head;
    if (first > n) first = n;
    memcpy(r->left + head, left, first * sizeof(float));
    memcpy(r->right + head, right, first * sizeof(float));
    uint32_t rest = n - first;
    if (rest) {
        memcpy(r->left, left + first, rest * sizeof(float));
        memcpy(r->right, right + first, rest * sizeof(float));
    }
    atomic_store_explicit(&r->head, (head + n) % r->slots, memory_order_release);
    return n;
}

uint32_t alk_ring_write_interleaved(alk_ring *r,
                                    const float *src,
                                    uint32_t channels,
                                    uint32_t frames) {
    if (channels == 0) return 0;
    uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    uint32_t writable = (r->slots - 1) - ring_readable(head, tail, r->slots);
    uint32_t n = frames < writable ? frames : writable;
    if (n == 0) return 0;

    uint32_t idx = head;
    for (uint32_t i = 0; i < n; i++) {
        const float *frame = src + (size_t)i * channels;
        float l = frame[0];
        r->left[idx] = l;
        r->right[idx] = channels > 1 ? frame[1] : l;
        if (++idx == r->slots) idx = 0;
    }
    atomic_store_explicit(&r->head, idx, memory_order_release);
    return n;
}

uint32_t alk_ring_read(alk_ring *r, float *left, float *right, uint32_t frames) {
    uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint32_t avail = ring_readable(head, tail, r->slots);
    uint32_t n = frames < avail ? frames : avail;
    if (n == 0) return 0;

    uint32_t first = r->slots - tail;
    if (first > n) first = n;
    memcpy(left, r->left + tail, first * sizeof(float));
    memcpy(right, r->right + tail, first * sizeof(float));
    uint32_t rest = n - first;
    if (rest) {
        memcpy(left + first, r->left, rest * sizeof(float));
        memcpy(right + first, r->right, rest * sizeof(float));
    }
    atomic_store_explicit(&r->tail, (tail + n) % r->slots, memory_order_release);
    return n;
}

uint32_t alk_ring_drop(alk_ring *r, uint32_t frames) {
    uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint32_t avail = ring_readable(head, tail, r->slots);
    uint32_t n = frames < avail ? frames : avail;
    if (n == 0) return 0;
    atomic_store_explicit(&r->tail, (tail + n) % r->slots, memory_order_release);
    return n;
}

// MARK: - Opaque-pointer retirement queue

struct alk_ptr_queue {
    void **storage;
    uint32_t slots;
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
};

alk_ptr_queue *alk_ptr_queue_create(uint32_t capacity) {
    if (capacity < 2) capacity = 2;
    alk_ptr_queue *queue = calloc(1, sizeof(alk_ptr_queue));
    if (!queue) return NULL;
    queue->slots = capacity + 1;
    queue->storage = calloc(queue->slots, sizeof(void *));
    if (!queue->storage) {
        free(queue);
        return NULL;
    }
    atomic_init(&queue->head, 0);
    atomic_init(&queue->tail, 0);
    return queue;
}

void alk_ptr_queue_destroy(alk_ptr_queue *queue) {
    if (!queue) return;
    free(queue->storage);
    free(queue);
}

bool alk_ptr_queue_push(alk_ptr_queue *queue, void *pointer) {
    if (!queue || !pointer) return false;
    uint32_t head = atomic_load_explicit(&queue->head, memory_order_relaxed);
    uint32_t next = (head + 1) % queue->slots;
    uint32_t tail = atomic_load_explicit(&queue->tail, memory_order_acquire);
    if (next == tail) return false;
    queue->storage[head] = pointer;
    atomic_store_explicit(&queue->head, next, memory_order_release);
    return true;
}

void *alk_ptr_queue_pop(alk_ptr_queue *queue) {
    if (!queue) return NULL;
    uint32_t tail = atomic_load_explicit(&queue->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&queue->head, memory_order_acquire);
    if (tail == head) return NULL;
    void *pointer = queue->storage[tail];
    queue->storage[tail] = NULL;
    atomic_store_explicit(&queue->tail, (tail + 1) % queue->slots, memory_order_release);
    return pointer;
}

// MARK: - Atomic meters / counters

struct alk_rt_state {
    _Atomic uint32_t out_peak_bits;
    _Atomic uint32_t pre_clip_peak_bits;
    _Atomic uint32_t pre_clip_true_peak_bits;
    _Atomic uint32_t true_peak_bits;
    _Atomic uint32_t cap_peak_bits;
    _Atomic bool clipped;
    _Atomic uint64_t clip_events;
    _Atomic uint64_t capture_callbacks;
    _Atomic uint64_t captured_frames;
    _Atomic uint64_t render_callbacks;
    _Atomic uint64_t rendered_frames;
    _Atomic uint64_t ring_read_frames;
    _Atomic uint64_t underruns;
    _Atomic uint64_t resyncs;
    _Atomic uint64_t capture_gaps;
    _Atomic uint32_t max_capture_gap_us;
    _Atomic uint32_t last_buffer_frames;
    _Atomic uint32_t max_capture_frames;
    _Atomic uint32_t max_render_frames;
    _Atomic uint32_t active_render_mode;
    _Atomic uint64_t active_render_generation;
    _Atomic bool running;
    _Atomic bool primed;
};

/// Lock-free max-update of a u32 (C11 has no fetch_max).
static void update_max_u32(_Atomic uint32_t *slot, uint32_t value) {
    uint32_t cur = atomic_load_explicit(slot, memory_order_relaxed);
    while (value > cur) {
        if (atomic_compare_exchange_weak_explicit(
                slot, &cur, value, memory_order_relaxed, memory_order_relaxed)) {
            break;
        }
    }
}

alk_rt_state *alk_state_create(void) {
    alk_rt_state *s = calloc(1, sizeof(alk_rt_state));
    return s;
}

void alk_state_destroy(alk_rt_state *s) {
    free(s);
}

void alk_state_set_running(alk_rt_state *s, bool running) {
    atomic_store_explicit(&s->running, running, memory_order_release);
}

bool alk_state_running(const alk_rt_state *s) {
    return atomic_load_explicit((_Atomic bool *)&s->running, memory_order_acquire);
}

void alk_state_set_primed(alk_rt_state *s, bool primed) {
    atomic_store_explicit(&s->primed, primed, memory_order_release);
}

bool alk_state_primed(const alk_rt_state *s) {
    return atomic_load_explicit((_Atomic bool *)&s->primed, memory_order_acquire);
}

/// Lock-free max-update of a non-negative float stored as bits.
static void update_peak_bits(_Atomic uint32_t *slot, float peak) {
    uint32_t new_bits;
    memcpy(&new_bits, &peak, sizeof(new_bits));
    uint32_t cur = atomic_load_explicit(slot, memory_order_relaxed);
    for (;;) {
        float cur_f;
        memcpy(&cur_f, &cur, sizeof(cur_f));
        if (!(peak > cur_f)) break;
        if (atomic_compare_exchange_weak_explicit(
                slot, &cur, new_bits, memory_order_relaxed, memory_order_relaxed)) {
            break;
        }
    }
}

void alk_state_note_capture(alk_rt_state *s, uint64_t frames, float peak) {
    atomic_fetch_add_explicit(&s->capture_callbacks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->captured_frames, frames, memory_order_relaxed);
    update_max_u32(&s->max_capture_frames, (uint32_t)frames);
    update_peak_bits(&s->cap_peak_bits, peak);
}

void alk_state_note_render(alk_rt_state *s, uint32_t buffer_frames) {
    atomic_fetch_add_explicit(&s->render_callbacks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->rendered_frames, buffer_frames, memory_order_relaxed);
    atomic_store_explicit(&s->last_buffer_frames, buffer_frames, memory_order_relaxed);
    update_max_u32(&s->max_render_frames, buffer_frames);
}

void alk_state_note_ring_read(alk_rt_state *s, uint64_t frames) {
    atomic_fetch_add_explicit(&s->ring_read_frames, frames, memory_order_relaxed);
}

void alk_state_note_output(alk_rt_state *s,
                           float peak,
                           float pre_clip_peak,
                           float pre_clip_true_peak,
                           float true_peak,
                           bool clipped) {
    update_peak_bits(&s->out_peak_bits, peak);
    update_peak_bits(&s->pre_clip_peak_bits, pre_clip_peak);
    update_peak_bits(&s->pre_clip_true_peak_bits, pre_clip_true_peak);
    update_peak_bits(&s->true_peak_bits, true_peak);
    if (clipped) {
        atomic_fetch_add_explicit(&s->clip_events, 1, memory_order_relaxed);
        atomic_store_explicit(&s->clipped, true, memory_order_relaxed);
    }
}

void alk_state_note_underrun(alk_rt_state *s) {
    atomic_fetch_add_explicit(&s->underruns, 1, memory_order_relaxed);
}

void alk_state_note_resync(alk_rt_state *s) {
    atomic_fetch_add_explicit(&s->resyncs, 1, memory_order_relaxed);
}

void alk_state_note_capture_gap(alk_rt_state *s, uint32_t gap_us) {
    atomic_fetch_add_explicit(&s->capture_gaps, 1, memory_order_relaxed);
    update_max_u32(&s->max_capture_gap_us, gap_us);
}

void alk_state_set_active_render_mode(alk_rt_state *s, uint32_t mode) {
    atomic_store_explicit(&s->active_render_mode, mode, memory_order_release);
}

uint32_t alk_state_active_render_mode(const alk_rt_state *s) {
    return atomic_load_explicit(
        (_Atomic uint32_t *)&s->active_render_mode,
        memory_order_acquire
    );
}

void alk_state_set_active_render_generation(alk_rt_state *s, uint64_t generation) {
    atomic_store_explicit(&s->active_render_generation, generation, memory_order_release);
}

uint64_t alk_state_active_render_generation(const alk_rt_state *s) {
    return atomic_load_explicit(
        (_Atomic uint64_t *)&s->active_render_generation,
        memory_order_acquire
    );
}

alk_stats alk_state_drain(alk_rt_state *s) {
    alk_stats out;
    uint32_t out_bits = atomic_exchange_explicit(&s->out_peak_bits, 0, memory_order_relaxed);
    uint32_t pre_clip_bits = atomic_exchange_explicit(&s->pre_clip_peak_bits, 0, memory_order_relaxed);
    uint32_t pre_clip_true_bits = atomic_exchange_explicit(&s->pre_clip_true_peak_bits, 0, memory_order_relaxed);
    uint32_t true_peak_bits = atomic_exchange_explicit(&s->true_peak_bits, 0, memory_order_relaxed);
    uint32_t cap_bits = atomic_exchange_explicit(&s->cap_peak_bits, 0, memory_order_relaxed);
    memcpy(&out.out_peak, &out_bits, sizeof(float));
    memcpy(&out.pre_clip_peak, &pre_clip_bits, sizeof(float));
    memcpy(&out.pre_clip_true_peak, &pre_clip_true_bits, sizeof(float));
    memcpy(&out.true_peak, &true_peak_bits, sizeof(float));
    memcpy(&out.cap_peak, &cap_bits, sizeof(float));
    out.clipped = atomic_exchange_explicit(&s->clipped, false, memory_order_relaxed);
    out.clip_events = atomic_exchange_explicit(&s->clip_events, 0, memory_order_relaxed);
    out.capture_callbacks = atomic_exchange_explicit(&s->capture_callbacks, 0, memory_order_relaxed);
    out.captured_frames = atomic_exchange_explicit(&s->captured_frames, 0, memory_order_relaxed);
    out.render_callbacks = atomic_exchange_explicit(&s->render_callbacks, 0, memory_order_relaxed);
    out.rendered_frames = atomic_exchange_explicit(&s->rendered_frames, 0, memory_order_relaxed);
    out.ring_read_frames = atomic_exchange_explicit(&s->ring_read_frames, 0, memory_order_relaxed);
    out.underruns = atomic_exchange_explicit(&s->underruns, 0, memory_order_relaxed);
    out.resyncs = atomic_exchange_explicit(&s->resyncs, 0, memory_order_relaxed);
    out.capture_gaps = atomic_exchange_explicit(&s->capture_gaps, 0, memory_order_relaxed);
    out.max_capture_gap_us = atomic_exchange_explicit(&s->max_capture_gap_us, 0, memory_order_relaxed);
    out.last_buffer_frames = atomic_load_explicit(&s->last_buffer_frames, memory_order_relaxed);
    out.active_render_mode = atomic_load_explicit(&s->active_render_mode, memory_order_acquire);
    out.active_render_generation = atomic_load_explicit(
        &s->active_render_generation,
        memory_order_acquire
    );
    return out;
}

uint32_t alk_state_last_buffer_frames(const alk_rt_state *s) {
    return atomic_load_explicit((_Atomic uint32_t *)&s->last_buffer_frames, memory_order_relaxed);
}

uint32_t alk_state_max_capture_frames(const alk_rt_state *s) {
    return atomic_load_explicit((_Atomic uint32_t *)&s->max_capture_frames, memory_order_relaxed);
}

uint32_t alk_state_max_render_frames(const alk_rt_state *s) {
    return atomic_load_explicit((_Atomic uint32_t *)&s->max_render_frames, memory_order_relaxed);
}

void alk_state_reset_quanta(alk_rt_state *s) {
    atomic_store_explicit(&s->max_capture_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&s->max_render_frames, 0, memory_order_relaxed);
}
