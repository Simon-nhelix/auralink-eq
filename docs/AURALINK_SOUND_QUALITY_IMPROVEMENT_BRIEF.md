# Auralink EQ Sound Quality Improvement Brief

이 문서는 Auralink EQ의 음질 개선 계획을 GPT Pro Extended 같은 고성능 모델에게 의뢰하기 위한 기술 브리프다. 목표는 막연한 "더 좋은 소리"가 아니라, 현재 앱 구조와 실시간 오디오 제약을 기준으로 어떤 DSP 개선이 실제 청감, 안정성, 지연시간, 유지보수성 면에서 가치가 큰지 판단받는 것이다.

## 1. 의뢰 목표

Auralink EQ는 macOS 시스템 전체 오디오에 20-band parametric EQ를 적용하는 앱이다. 현재는 RBJ Audio EQ Cookbook 기반 biquad IIR 필터를 실시간으로 적용한다.

우리가 알고 싶은 핵심 질문은 다음이다.

1. 현재 biquad IIR 기반 EQ 엔진에서 먼저 개선해야 할 음질/안정성 항목은 무엇인가?
2. FIR, convolution, linear-phase/minimum-phase correction 같은 디지털 필터를 추가할 가치가 있는가?
3. 시스템 전체 오디오 앱이라는 제약에서 청감상 이득이 큰 개선 순서는 무엇인가?
4. "고급 DSP 기능"보다 먼저 갖춰야 할 측정, 검증, A/B 테스트 체계는 무엇인가?
5. 현실적인 MVP -> 고급 모드 로드맵은 어떻게 짜는 것이 좋은가?

## 2. 제품 개요

Auralink EQ는 macOS menubar 앱이며, 시스템 오디오를 BlackHole 같은 virtual loopback device로 캡처한 뒤 EQ DSP를 거쳐 실제 출력 장치로 재생한다.

대략적인 신호 흐름:

```text
System audio
  -> BlackHole / virtual loopback capture device
  -> Auralink input engine
  -> lock-free ring buffer
  -> output engine render callback
  -> EQProcessor
  -> selected physical output device
  -> headphones / DAC
```

주요 코드 위치:

- `Sources/AuralinkCore/DSP/Biquad.swift`
- `Sources/AuralinkCore/DSP/EQProcessor.swift`
- `Sources/AuralinkCore/DSP/FrequencyResponse.swift`
- `Sources/AuralinkCore/Presets/PresetValidator.swift`
- `Sources/AuralinkApp/Audio/AudioRoutingEngine.swift`
- `Sources/AuralinkRT/auralink_rt.c`
- `mcp-server/src/index.ts`
- `mcp-server/src/validate.ts`
- `mcp-server/src/autoeq.ts`

## 3. 현재 DSP 구현 상태

### 3.1 EQ 필터

현재 EQ는 최대 20개 band를 cascade하는 parametric EQ다.

지원 필터 타입:

- Bell / peaking EQ
- Low shelf
- High shelf
- Low pass
- High pass
- Notch

필터 특성:

- RBJ Audio EQ Cookbook 공식 기반 coefficient 계산
- Direct Form II Transposed 구조
- `Float` 오디오 샘플 처리, coefficient와 상태는 Swift `Double` 기반
- 주파수 범위: 20 Hz ... 20,000 Hz
- gain 범위: -18 dB ... +18 dB
- Q 범위: 0.1 ... 10
- preamp 범위: -24 dB ... 0 dB
- stereo / left / right channel band 지원

현재 구현상 장점:

- gain이 0 dB에 가까운 gain filter는 identity 처리
- disabled band는 처리하지 않음
- Nyquist 근처 cutoff guard 있음
- NaN/inf 방어 있음
- sample-rate별 coefficient 재계산
- offline frequency-response 계산이 realtime DSP와 같은 biquad math를 사용

### 3.2 실시간 처리와 anti-click

`EQProcessor`는 다음 click/pop 방어를 갖고 있다.

- preset update 시 같은 cascade slot의 filter state를 carry-over
- preamp 변경은 약 5 ms one-pole smoother로 ramp
- bypass/enable은 약 5 ms dry/wet crossfade
- fully bypass 상태에서는 preamp와 soft clip guard까지 건너뛰어 bit-perfect pass-through 지향
- control thread가 coefficient rebuild 중이면 realtime thread는 lock을 기다리지 않고 해당 buffer를 passthrough

### 3.3 clipping/headroom 처리

현재 clipping 관련 구조:

- `PresetValidator`가 frequency response를 sampling해서 peak boost를 추정
- auto-preamp는 target headroom을 기준으로 negative preamp 제안
- realtime path에는 high-knee soft clip guard가 있음
- render callback은 soft clip guard 이전 peak를 반환받아 clipping telemetry에 사용
- Safe Mode는 response peak 기반으로 guard preamp를 강제 적용

중요한 현재 제약:

- true peak / inter-sample peak limiter는 아직 없음
- compressor/limiter 계열 dynamic processing은 없음
- soft clip은 사고 방지용 guard에 가깝고 mastering limiter가 아님

## 4. 현재 오디오 라우팅 구현 상태

macOS에서 system-wide EQ를 위해 capture device와 output device가 다르기 때문에 두 AVAudioEngine을 사용한다.

라우팅 특징:

- input engine: virtual capture device에서 오디오 수신
- output engine: selected output device로 재생
- C 기반 lock-free SPSC ring buffer로 두 device clock domain 연결
- render scratch buffers는 사전 할당
- audio thread에서 Swift lock/alloc을 피하는 설계
- capture/render quanta 기반 adaptive cushion
- varispeed node를 이용한 drift servo
- underrun 시 fade-out + reprime
- ring fill이 과도하게 늘면 fade resync
- HAL overload/capture gap/underrun/resync telemetry

중요한 현재 제약:

- system-wide routing은 virtual device 설정에 의존한다.
- device clock drift, underrun, CPU scheduling이 음질 안정성에 직접 영향을 준다.
- 어떤 DSP를 추가하든 render callback에서 allocation/blocking이 없어야 한다.
- latency 증가는 제품 경험에 바로 영향을 준다.

## 5. MCP / AI 튜닝 상태

Auralink는 자체 AI 모델이 아니라 local audio engine, preset store, validator, headphone knowledge base, live audition/apply endpoint다.

현재 MCP 서버는 다음 류의 기능을 제공한다.

- current audio state 읽기
- output device 목록 읽기
- headphone profile 목록/상세 읽기
- preset 목록/상세 읽기
- preset 생성/검증/삭제
- unsaved audition preset 적용
- 현재 audition 저장
- saved preset live apply / rollback
- AutoEq measured correction 조회
- response curve 계산

AI tuning workflow의 핵심 규칙:

- headphone/IEM 모델명이 있으면 AutoEq measured correction을 먼저 조회한다.
- 측정 기반 correction이 있으면 그 band와 preamp를 baseline으로 사용한다.
- preference tuning은 baseline 위에 작은 band를 추가하고 먼저 audition한다.
- 사용자가 좋아하거나 저장을 요청하기 전에는 preference 실험을 저장하지 않는다.
- live audition/apply는 사용자의 명시 요청이 있을 때만 수행한다.

## 6. 음질 개선에서 중요한 제품 제약

### 6.1 실시간 시스템 오디오

이 앱은 DAW plugin이나 offline renderer가 아니라 system-wide EQ다. 따라서 우선순위는 다음과 같다.

1. click/pop/underrun 없는 안정성
2. 낮고 예측 가능한 latency
3. clipping/headroom 안전성
4. CPU 사용량과 배터리 영향
5. 청감상 의미 있는 tonal correction
6. 고급 모드의 optional quality features

### 6.2 대상 사용자 경험

사용자는 YouTube, Apple Music, Spotify, 게임, 회의, 브라우저 오디오 등 모든 소리를 이 경로로 들을 수 있다. 따라서 고급 필터가 있더라도 기본값은 보수적이어야 한다.

피해야 할 방향:

- phase/latency tradeoff를 숨긴 linear-phase 필터 기본 적용
- clipping을 유발하는 과한 loudness boost
- 측정 근거 없는 headphone correction
- "AI enhancer", exciter, stereo widener 같은 설명하기 어려운 효과를 기본 음질 개선으로 포장
- CPU spike나 allocation을 유발하는 render-path 처리

## 7. 디지털 필터 개선 후보

아래 후보들은 GPT Pro Extended에게 평가를 요청할 항목이다. 순위는 아직 확정이 아니다.

### 7.1 현재 IIR biquad 엔진 개선

가능한 개선:

- filter coefficient interpolation 또는 smoother 구조 검토
- preset update 때 단순 slot-by-slot state carry-over가 충분한지 검토
- cascade ordering 최적화
- high-Q / high-gain / low-frequency extreme case 안정성 검증 강화
- denormal number 방어 필요성 검토
- stereo-linked band 처리와 L/R-only band의 response visualization 정합성 개선
- shelving filter의 Q/S 해석이 사용자 기대와 맞는지 검토
- oversampling이 필요한 케이스가 있는지 검토

예상 장점:

- latency 증가 거의 없음
- 현재 구조와 가장 잘 맞음
- CPU 부담 낮음
- system-wide 기본 경로로 적합

예상 한계:

- phase response를 사용자가 선택할 수 없음
- headphone correction에서 아주 세밀한 curve matching은 FIR보다 제한적
- 많은 band가 겹치면 gain/phase response 설명이 어려워질 수 있음

### 7.2 FIR / convolution correction

가능한 개선:

- optional convolution engine
- minimum-phase FIR correction
- linear-phase FIR correction
- partitioned convolution
- AutoEq impulse response 또는 generated FIR support
- latency budget별 quality modes

검토해야 할 tradeoff:

- FIR length에 따른 latency
- CPU와 memory 사용량
- pre-ringing, especially linear-phase correction
- video/gaming/call use case에서 latency 허용 범위
- runtime filter swap 시 click-free transition
- sample-rate별 impulse response 관리
- 현재 ring/cushion latency에 추가되는 총 latency

가설:

- 기본 모드는 IIR가 적합할 가능성이 높다.
- FIR/convolution은 "High Quality Correction Mode" 같은 optional feature로 검토하는 편이 안전하다.
- headphone correction 목적이라면 linear-phase보다 minimum-phase 쪽이 system-wide listening에 더 자연스러울 수 있다.

### 7.3 Headroom, true-peak, limiter

가능한 개선:

- true peak estimation
- inter-sample peak oversampling meter
- lookahead limiter optional mode
- transparent peak limiter instead of soft clip guard
- loudness-matched A/B compare
- clipping event history와 preset-level warning 강화

핵심 질문:

- soft clip guard를 유지하되 limiter를 추가할 가치가 있는가?
- lookahead limiter의 latency가 system-wide EQ에서 허용되는가?
- limiter가 "음질 향상"인지, safety tool인지 제품 메시지를 어떻게 분리할 것인가?

### 7.4 측정과 검증 도구

가능한 개선:

- impulse response export
- swept sine test harness
- null test / bypass transparency test
- THD+N 또는 harmonic distortion sanity test
- CPU benchmark per sample rate / band count
- filter update click/pop regression test
- latency measurement
- realtime underrun stress test
- Swift DSP와 TypeScript validator response parity test

가설:

- 고급 필터보다 측정/검증 체계를 먼저 만드는 것이 장기적으로 더 큰 음질 개선을 만든다.
- "소리가 좋아졌다"를 판단하려면 response, peak, latency, glitch counter, loudness-matched A/B가 필요하다.

### 7.5 AutoEq / headphone correction 품질

가능한 개선:

- AutoEq source priority policy
- model alias matching 개선
- correction baseline과 preference bands를 분리 저장
- target curve blending
- user hearing / seal / pad wear / taste adjustment workflow
- response curve에서 correction vs preference contribution 시각화

핵심 질문:

- DSP engine 자체보다 "좋은 correction을 어떻게 고르고 적용하는가"가 더 큰 음질 차이를 만들 수 있는가?
- 측정 source 간 차이를 사용자에게 어떻게 노출할 것인가?

## 8. 추천 의뢰 방식

GPT Pro Extended에게는 "기능을 많이 추가해줘"가 아니라 다음 산출물을 요구하는 것이 좋다.

1. IIR 유지/개선 vs FIR/convolution 추가에 대한 명확한 권고
2. 청감상 이득, 구현 리스크, latency/CPU 영향 기준의 우선순위 표
3. phase 0/1/2/3 로드맵
4. 각 phase의 acceptance criteria
5. 필요한 테스트/측정 계획
6. 현재 구조에서 수정해야 할 파일/모듈 단위 제안
7. 하면 안 되는 DSP 아이디어와 이유
8. 사용자가 체감할 UX 변경안

## 9. 제안하는 초안 로드맵

이 로드맵은 확정안이 아니라 GPT Pro Extended에게 검토받을 baseline이다.

### Phase 0: Measurement First

목표: 현재 엔진이 얼마나 투명하고 안정적인지 수치화한다.

작업 후보:

- flat/bypass null test 추가
- impulse response/swept sine 기반 frequency response verification
- sample rate별 CPU benchmark
- 20-band worst-case preset stress test
- filter update click/pop regression test
- app telemetry에 clipping/underrun/resync history 저장
- TypeScript validator와 Swift response parity test

성공 기준:

- flat preset이 audible band에서 사실상 unity임을 자동 검증
- bypass path가 bit-perfect임을 유지
- worst-case preset에서도 render callback이 allocation/blocking 없이 동작
- response curve가 Swift/MCP에서 일치

### Phase 1: Safer, Better IIR Path

목표: 기본 경로의 음질과 안정성을 개선한다.

작업 후보:

- coefficient smoothing 전략 검토/개선
- state carry-over의 edge case 테스트
- denormal 방어
- cascade ordering policy 추가 여부 검토
- Safe Mode와 auto-preamp UX 정리
- true peak meter 또는 oversampled peak estimator 검토
- loudness-matched A/B compare

성공 기준:

- live band drag, preset switch, bypass toggle에서 click/pop regression 감소
- clipping risk가 사용자와 AI에게 더 정확히 전달됨
- 기본 latency 증가 없음

### Phase 2: Correction Quality

목표: "좋은 필터"보다 "좋은 목표와 보정"에 집중한다.

작업 후보:

- AutoEq baseline preset metadata 강화
- measured correction과 preference adjustment를 분리
- source confidence 표시
- target curve blend/strength control
- headphone profile alias/source 관리
- response curve summary 개선

성공 기준:

- AI가 측정 기반 baseline을 안정적으로 만들 수 있음
- 사용자가 baseline과 preference 변화를 구분할 수 있음
- 과한 correction이 줄고 작은 preference tuning workflow가 좋아짐

### Phase 3: Optional Advanced Filter Mode

목표: latency를 감수하는 사용자를 위해 고급 필터를 optional로 제공할 수 있는지 검증한다.

작업 후보:

- minimum-phase FIR prototype
- partitioned convolution prototype
- filter-length별 latency/CPU 측정
- sample-rate별 IR management
- IIR/FIR mode switching crossfade
- HQ correction mode UI

성공 기준:

- 기본 모드는 변하지 않음
- FIR mode는 명시적 opt-in
- latency/CPU/phase tradeoff가 UI와 docs에 명확함
- 실제 청감상 이득이 측정과 A/B로 확인됨

## 10. GPT Pro Extended에 붙여넣을 프롬프트

아래 프롬프트를 그대로 붙여넣고, 필요하면 이 문서 전체를 같이 첨부한다.

```text
You are advising on DSP and product planning for Auralink EQ, a macOS system-wide audio EQ app.

Please read the technical brief below and produce a practical sound-quality improvement plan. I am especially considering digital-filter upgrades such as better IIR handling, FIR/convolution, minimum-phase correction, linear-phase correction, true-peak limiting, and measurement tooling.

Context:
- Auralink EQ is a macOS menubar app for system-wide sound.
- Signal path: system audio -> BlackHole/virtual loopback capture -> Auralink input engine -> lock-free SPSC ring buffer -> output engine render callback -> EQProcessor -> selected physical output device.
- Current EQ engine: up to 20 parametric bands, RBJ Cookbook biquad IIR filters, Direct Form II Transposed, Float sample processing with Double coefficients/state, preamp, bypass crossfade, preamp smoothing, soft clip guard.
- Current filter types: bell, low shelf, high shelf, low pass, high pass, notch.
- Realtime constraints: no allocation/blocking in render path; low predictable latency matters; click/pop/underrun avoidance matters more than exotic DSP.
- Current safety: offline frequency response estimator, preset validator, suggested auto-preamp, Safe Mode guard preamp, realtime soft clip guard, clipping telemetry from pre-guard peak.
- Current AI/MCP workflow: AutoEq measured correction first, response curve verification, audition preference tunings before saving, live apply only with explicit user confirmation.

Relevant source files:
- Sources/AuralinkCore/DSP/Biquad.swift
- Sources/AuralinkCore/DSP/EQProcessor.swift
- Sources/AuralinkCore/DSP/FrequencyResponse.swift
- Sources/AuralinkCore/Presets/PresetValidator.swift
- Sources/AuralinkApp/Audio/AudioRoutingEngine.swift
- Sources/AuralinkRT/auralink_rt.c
- mcp-server/src/index.ts
- mcp-server/src/validate.ts
- mcp-server/src/autoeq.ts

Please answer in this structure:

1. Executive recommendation:
   - Should the default path stay IIR biquad?
   - Should FIR/convolution be added now, later, or not at all?
   - What is the highest-leverage sound-quality work?

2. Prioritized roadmap:
   - Phase 0: measurement and validation
   - Phase 1: low-risk IIR/audio-path improvements
   - Phase 2: correction quality and AI workflow improvements
   - Phase 3: optional advanced filters, if justified

3. DSP architecture recommendations:
   - IIR improvements
   - FIR/convolution feasibility
   - limiter/true-peak strategy
   - coefficient smoothing / filter transition strategy
   - latency and CPU budget

4. Test and measurement plan:
   - automated tests
   - offline DSP tests
   - realtime stress tests
   - listening/A-B tests
   - metrics and acceptance criteria

5. Risk matrix:
   - audible artifacts
   - latency
   - CPU/battery
   - implementation complexity
   - UX confusion
   - correctness of AI-generated EQ

6. Implementation task breakdown:
   - concrete modules/files to touch
   - task order
   - acceptance criteria for each task

7. Things not to build yet:
   - features that sound attractive but are likely to harm quality, latency, trust, or maintainability.

Please be opinionated. If FIR/linear-phase filtering is not worth it for a system-wide default path, say so clearly and explain when it would become worth it. Prefer practical engineering tradeoffs over audiophile marketing language.
```

## 11. GPT에게 추가로 던질 후속 질문

첫 답변을 받은 뒤에는 아래 질문으로 더 구체화하면 좋다.

1. "이 로드맵에서 이번 주에 시작할 3개 작업만 고른다면 무엇인가?"
2. "현재 Swift `EQProcessor`에 coefficient interpolation을 넣는다면 어떤 방식이 가장 안전한가?"
3. "minimum-phase FIR prototype을 만든다면 latency budget과 filter length를 어떻게 잡아야 하는가?"
4. "soft clip guard를 true-peak limiter로 바꾸는 것이 좋은가, 아니면 둘을 별도 safety layer로 둬야 하는가?"
5. "Auralink의 MCP/AI tuning workflow에서 correction quality를 높이는 가장 큰 UX 변경은 무엇인가?"

## 12. 현재 판단

현재 코드 구조를 기준으로 한 임시 판단은 다음과 같다.

- 기본 재생 경로는 계속 IIR biquad 중심으로 가는 편이 안전하다.
- FIR/convolution은 흥미롭지만 system-wide 기본값으로 바로 넣기에는 latency, CPU, UX tradeoff가 크다.
- 가장 먼저 할 일은 측정/검증 체계 강화다.
- 그다음은 click-free transition, true-peak/headroom, loudness-matched A/B 같은 청감 신뢰도 작업이다.
- AutoEq와 preference tuning의 분리가 DSP 엔진 교체보다 실제 사용자 만족도에 더 큰 영향을 줄 수 있다.
- 고급 필터는 opt-in "HQ correction mode"로 prototype하고, 측정과 A/B로 이득이 확인될 때 제품화하는 것이 좋다.
