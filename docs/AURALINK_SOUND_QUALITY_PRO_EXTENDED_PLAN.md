# Auralink EQ Sound Quality Roadmap

작성일: 2026-06-15

이 문서는 `AURALINK_SOUND_QUALITY_IMPROVEMENT_BRIEF.md`를 ChatGPT Pro Extended에 넣어 받은 권고를 바탕으로 정리한 실행계획이다. 원 브리프는 "무엇을 물을 것인가"에 가깝고, 이 문서는 "무엇부터 만들 것인가"에 집중한다.

## 진행 로그

### 2026-07-13 — 측정 기반 FIR 제품 경로

- 기존 512-tap IIR 복제 prototype은 제품 경로에서 제거하고 회귀/비교 fixture로만 남겼다. `AURALINK_EXPERIMENTAL_FIR` gate는 더 이상 사용하지 않는다.
- AutoEq `GraphicEQ.txt`의 dense magnitude curve를 PEQ와 함께 다운로드·검증·캐시하고, preamp를 curve에서 제거한 versioned `MeasuredCorrectionPayload`를 preset에 provenance/hash와 함께 영구 저장한다.
- `MeasuredFIRDesigner`는 44.1/48/96/192 kHz별 최소위상 impulse를 설계한다. 10 kHz 위 measurement uncertainty는 regularize하고, 구현 최대/RMS 오차와 PEQ 대비 절대/상대 개선 gate를 모두 통과한 경우에만 FIR을 허용한다.
- 렌더 의미를 분리했다. Standard IIR은 기존 전체 band를 그대로 처리한다. Measured FIR은 `measured baseline FIR → preferenceBandIndexes IIR → global preamp 1회`이며 baseline PEQ band를 중복 적용하지 않는다.
- `PartitionedFIRConvolver`는 direct head + FFT tail로 causal impulse의 첫 sample을 즉시 내보내고, 임의 callback segmentation을 무할당/무락으로 처리한다. 전환 중 두 FIR도 block-vDSP로 계산한 뒤 crossfade한다.
- 측정 payload 누락/손상, sample-rate 설계 실패, 품질/개선 gate 실패는 모두 Standard IIR로 fail-closed 한다. Luxsin X8은 계속 PEQ만 사용한다.
- FIR Lab은 항상 보이되 현재 preset의 가용성, sample rate, tap/partition, PEQ 대비 오차 개선 또는 잠긴 이유를 설명한다. 제품 주장은 “FIR 음질 우월”이 아니라 “저장된 측정 target 대비 잔여 오차 감소”로 제한한다.
- 독립 리뷰 후 measured payload canonical SHA-256, exact cache identity, L/R worst-channel gate, 10–16 kHz regularization fit, Luxsin PEQ-only validation, RT-committed mode/generation telemetry를 추가했다. FIR/chain 상태 파괴는 C11 SPSC retirement queue로 control thread에 넘기고, preamp/bypass/combined transition도 block-vDSP로 처리한다.
- MCP는 control acceptance와 실제 audible 상태를 분리한다. expected preset id와 request generation이 현재 state의 requested/committed generation과 모두 일치하고, routing active + system routed + EQ enabled일 때만 `audible:true`를 반환한다. rollback target이 없으면 `ok:false`다.
- 검증: Swift 130개, MCP 29개, Release steady 56개 case, IIR↔FIR transition 28개 case, FIR control-ramp 28개 case 통과. 44.1–192 kHz, 64–8192 frames, steady heap net-retention 0을 gate로 고정했다. CPU-time compute gate와 live RT underrun/resync 검증은 서로 다른 증거로 명시한다.

### 2026-07-10 (구형 512-tap prototype 당시 기록)

- Correctness gate 완료: 실제 left/right response API를 추가하고 Swift/TypeScript validator가 두 출력 채널의 최대 peak로 headroom을 계산한다. 반대 방향 L/R 밴드가 상쇄되어 clipping을 놓치던 경로를 fixture로 고정했다.
- shelf 파라미터는 기존 preset, AutoEq, hardware PEQ 호환을 위해 `Slope/S`가 아니라 `Q`로 계약을 확정하고 독립 RBJ-Q oracle 테스트를 추가했다.
- `TuningEngine.makeTuning(basePreset:)`이 baseline band/slot/channel/preamp를 보존한 채 빈 slot에 preference를 추가한다. unknown/estimated source correction strength는 최대 50%로 제한한다.
- Standard IIR의 always-on soft clip을 제거했다. 0 dBFS flat PCM은 bit-transparent하며 nonlinear guard는 Safe Mode에서만 켜진다.
- `EQProcessor` 제어 변경을 prepared-state mailbox로 바꿨다. publication lock 경합 시 dry buffer를 내보내지 않고 마지막 committed DSP state를 계속 렌더한다. 진행 중 fade에는 최신 edit만 보류해 16 ms 편집이 약 46 ms fade를 반복 초기화하지 않는다.
- 당시 FIR impulse는 Standard IIR 편집에서 만들지 않고 구형 experimental FIR을 선택할 때만 lazy design했다.
- true-peak를 buffer-stateful ITU-R BS.1770 4-phase FIR로 교체했다. pre-protection/post-output true peak를 분리하고 inter-sample over로 clipping event를 판정한다.
- A/B level proxy를 response dB 단순 평균에서 K-weighted linear-power average로 교체했다. 이는 live LUFS meter가 아닌 deterministic response proxy로 명확히 표기한다.
- CoreAudio capture/output latency와 safety offset을 기존 ring-fill estimate에 포함했다.
- Release benchmark executable을 추가했다: `swift run -c release AuralinkBenchmarks`. 44.1/48/96/192 kHz × 64…1024 frames × IIR/FIR를 측정한다.
- 현재 머신의 final worst-case 20-band IIR 결과는 p99 callback deadline gate 20/20 통과, 최악 18.49%였다. steady-state heap net-growth도 40/40 case에서 없었다.
- 당시 512-tap FIR dense 품질 gate 결과: broad correction은 44.1/48/96 kHz에서 통과했으나 192 kHz에서 실패했고, low-frequency/high-Q/20-band 시나리오는 표준 rate에서도 최대 11.247 dB 오차로 실패했다.
- 당시 ship 결정: **no-ship**. 이 결정은 IIR impulse를 512 taps로 자른 prototype에 대한 것이며, 2026-07-13의 독립 measured-curve/adaptive FIR 경로가 이를 대체했다.
- 검증: Swift 111개, MCP 19개 통과.

### 2026-06-15

- Sprint 1 시작.
- `bypass/flat/impulse/null` 성격의 Swift DSP 품질 테스트를 추가했다.
- Swift `FrequencyResponse`와 MCP `validate.ts`가 공유하는 response parity fixture를 추가했다.
- MCP에 Node 기본 테스트 러너를 연결했다.
- parity fixture 작성 중 MCP `validate.ts`가 ideal notch 중심에서 Swift와 다른 dB floor를 쓰는 문제를 발견했고, Swift와 동일하게 linear magnitude를 `1e-9`로 floor하도록 수정했다.
- preset switch와 live band drag 전환의 click/pop 회귀를 감시하는 `TransitionMetrics` 테스트를 추가했다. metric은 출력 인접 샘플 step에서 원본 입력의 자연스러운 step을 뺀 excess step으로 계산한다.
- post-EQ telemetry에 pre-clip peak, estimated true-peak, clip event count/history를 추가했다. RT path는 C atomic max/counter만 갱신하고, SwiftUI Monitor와 `/debug`가 clip 이벤트를 볼 수 있게 했다.
- Sprint 2 시작: `EQProcessor`의 filter-state handoff를 cascade slot 기준에서 stable band index 기준으로 바꿨다. 앞 band가 꺼져 섹션 순서가 당겨져도 다른 band의 delay state를 잘못 물려받지 않는다.
- band index가 바뀐 새 섹션이 이전 index의 settled state를 상속하지 않는 회귀 테스트를 추가했다.
- `EQProcessor`에 old→new dual-cascade crossfade를 추가했다. preset update 후 삭제/추가/타입 변경된 band도 즉시 새 chain으로 점프하지 않고 기존 cascade에서 새 cascade로 짧게 페이드한다.
- 삭제된 band가 dry로 한 샘플 만에 떨어지지 않는지, 전환 후 새 chain이 fresh 기준과 맞는지 검증하는 회귀 테스트를 추가했다.
- UI drag/table edit coalescing을 추가했다. `currentPreset`과 response graph는 즉시 갱신하지만, realtime engine의 full preset apply는 약 16 ms 단위로 합쳐서 filter cascade rebuild 빈도를 낮춘다.
- 예약된 engine apply는 snapshot이 아니라 실행 시점의 최신 `currentPreset`을 적용한다. preset load, reset, A/B 같은 명시적 명령은 예약 작업을 취소하고 즉시 적용한다.
- `Biquad` hot path에 denormal clamp를 추가했다. 약 -600 dBFS 이하의 numerically irrelevant tail/state를 0으로 접어, 무음 근처에서 subnormal 값이 audio thread CPU를 흔드는 일을 막는다.
- Float subnormal 크기는 0으로 flush하고, `1e-20` 수준의 조용하지만 정상적인 샘플은 보존하는 회귀 테스트를 추가했다.
- state carry-over 정책을 개선했다. 같은 band index라도 filter type이 바뀌거나 frequency/Q/gain이 크게 점프하면 새 cascade는 fresh state로 시작하고, old→new crossfade가 전환을 맡는다.
- compatible handoff 기준을 추가했다: 같은 type, frequency ratio ≤ 1.5×, Q ratio ≤ 4×, gain delta ≤ 9 dB일 때만 delay state를 이어받는다. filter type 변경 시 state를 잘못 상속하지 않는 회귀 테스트를 추가했다.
- shelf Q/S UX를 정리했다. JSON/MCP wire field는 호환성을 위해 `q`로 유지하고, UI/AI 요약/validator/MCP schema에서는 low/high shelf를 Q가 아닌 Slope/S로 표시한다.
- Sprint 2 항목 6개를 모두 반영했다. 다음 우선순위는 Sprint 3의 true-peak 신뢰도 개선, Safe Mode/auto-preamp 문구 정리, loudness-matched A/B이다.
- Sprint 3 시작: render path에 lightweight inter-sample true-peak estimator를 추가했다. post-guard sample peak와 estimated true peak를 분리해서 RT atomic telemetry로 전달하고, pre-guard clipping peak는 별도 신호로 유지한다.
- TopBar/MenuBar peak readout은 estimated true peak 기준(dBTP)으로 바꾸고, Diagnostics에는 Output sample peak, Est. true, Pre-clip을 나란히 보여 headroom 원인을 구분할 수 있게 했다.
- true-peak estimator는 4x Catmull-Rom probe 기반의 가벼운 추정치다. ITU-R BS.1770급 oversampling meter는 아니며, 향후 필요하면 별도 고정밀 meter로 교체한다.
- 검증: `swift test`, `npm test` 통과.

### 2026-06-16

- Sprint 3 완료: Safe Mode/auto-preamp 문구를 guard preamp 기준으로 정리하고, proposed tuning A/B는 loudness-matched before snapshot을 임시 적용하도록 바꿨다.
- Swift/MCP validator에 low-bass boost, narrow boosted treble, headroom warning을 추가했다. aggregate boost 경고는 band 단순합이 아니라 response peak 기반으로 판단한다.
- Sprint 4 완료: Swift preset model과 MCP schema에 `CorrectionMetadata`를 추가해 baseline/preference/combined 역할, source confidence, correction strength, target blend, preference band indexes를 저장한다.
- AI Tuning 패널에 correction strength와 target blend slider를 추가했다. 새 튜닝의 기본값은 light 방향으로 `70% / 85%`에서 시작하고, 기존 correction metadata가 있으면 그 값을 이어받는다.
- response graph는 baseline preset이 있는 preference/combined preset에서 baseline curve와 delta contribution을 점선으로 함께 보여준다.
- Headphone preset list와 AI proposal card는 correction role/source confidence/strength/blend를 표시한다.
- 검증: `swift test` 76개 통과, `npm test` 3개 통과.
- Sprint 5 구형 prototype 완료: `FIRDesigner`가 현재 parametric preset의 minimum-phase FIR approximation을 만들고, `FIRConvolver`가 short-FIR convolution path를 제공한다.
- `EQProcessor`에 `standard_iir` / `hq_fir` render mode를 추가했다. IIR은 기본값으로 유지하고, 당시 prototype은 사용자-facing `Silky FIR` opt-in toggle로만 열었다.
- 당시 Silky FIR 전환과 FIR preset update는 기존 wet-path crossfade를 사용해 한 버퍼 점프 없이 넘어갔다.
- sample-rate/preset-topology/length 기반 `FIRDesignCache`를 추가해 같은 보정 구조의 impulse response를 재사용한다.
- 현재 FIR path는 512-tap vDSP block convolution prototype이다. FFT partitioned convolution과 제품화 여부는 실제 CPU/latency/A-B 결과를 보고 결정한다.
- 검증: `swift test` 81개 통과, `npm test` 3개 통과.
- 당시 Silky FIR live preview 안정화: realtime path는 512 taps를 유지하고, 안정 상태에서는 Accelerate/vDSP block convolution으로 처리했다. 이 경로는 2026-07-13 measured FIR로 대체되었다.

## 1. 핵심 결정

### 기본 재생 경로는 IIR biquad 유지

Auralink EQ의 기본 path는 계속 IIR biquad 기반으로 유지한다. 이 앱은 system-wide 오디오 앱이므로 "가장 고급스러운 필터"보다 낮은 지연시간, click/pop 없는 전환, underrun 없는 안정성, render callback의 무할당/무락 보장이 더 중요하다.

현재 RBJ Cookbook 기반 biquad 구조는 parametric EQ의 기본 경로로 적절하다. 개선은 엔진 교체보다 측정 가능성, 전환 안정성, headroom 신뢰도, correction workflow에서 먼저 해야 한다.

### 측정 기반 minimum-phase FIR은 opt-in 고급 모드

Standard IIR은 계속 기본값이다. 다만 dense measured curve가 preset에 저장되어 있고 sample-rate별 정확도·PEQ 대비 개선·realtime gate를 통과하면 `Measured FIR`을 명시적으로 선택할 수 있다. 이 모드는 IIR을 FIR로 복제하는 것이 아니라, PEQ가 근사하던 독립 측정 target을 더 정밀하게 렌더한다.

Linear-phase 필터는 여전히 제품 경로에 넣지 않는다. latency와 pre-ringing tradeoff를 숨기면 제품 신뢰를 해치며, 음악뿐 아니라 영상·게임·회의 오디오까지 지나는 system-wide 기본값으로 적합하지 않다.

### 가장 높은 레버리지

우선순위는 다음 순서다.

1. 측정/검증 체계
2. click-free IIR transition
3. headroom/true-peak 관측
4. AutoEq 보정 품질과 UX
5. optional advanced filter prototype

## 2. 우선순위 표

| 우선순위 | 작업 | 청감 이득 | 리스크 | latency 영향 | 권고 |
| ---: | --- | --- | --- | --- | --- |
| 0 | 측정/검증 harness | 매우 큼 | 낮음~중간 | 없음 | 즉시 |
| 1 | preset/band 전환 click regression 개선 | 큼 | 중간 | 없음 | 즉시 |
| 2 | true-peak meter + clipping history | 큼 | 중간 | 없음 또는 매우 작음 | 즉시 |
| 3 | loudness-matched A/B | 큼 | 중간 | 없음 | Phase 1 |
| 4 | AutoEq baseline/preference 분리 | 매우 큼 | 중간 | 없음 | Phase 2 |
| 5 | target strength/blend UX | 큼 | 중간 | 없음 | Phase 2 |
| 6 | transparent limiter | 중간 | 중간~높음 | 있음 | opt-in |
| 7 | minimum-phase FIR | 불확실~중간 | 높음 | 작게 만들 수 있으나 복잡 | prototype |
| 8 | linear-phase FIR | niche | 높음 | 큼 | 음악 전용 opt-in 후보 |
| 9 | enhancer/exciter/widener | 불확실 | 높음 | 다양 | 하지 말 것 |

## 3. 제품 모드

### Low Latency IIR Mode

기본 모드다.

- 현재 biquad cascade 기반
- latency 증가 없음
- system-wide 기본 path
- AutoEq baseline과 preference tuning의 기본 적용 대상
- clipping/true-peak 관측 강화

### Clip Protection Mode

안전 모드다.

- auto-preamp 강화
- true-peak meter
- clipping event history
- 필요 시 limiter는 별도 opt-in으로 검토
- "음질 향상"이 아니라 "안전 보호"로 설명

### Measured FIR / HQ Correction Mode

측정 data가 있는 preset에만 열리는 고급 opt-in 모드다.

- 사용자-facing 이름은 `Measured FIR`
- 목적은 저장된 dense measurement target 대비 PEQ 잔여 오차를 줄이는 것
- sample-rate-adaptive minimum-phase synthesis + direct-head/partitioned-tail convolution
- baseline FIR 뒤에는 `preferenceBandIndexes`의 IIR만 적용하고 preamp는 한 번만 적용
- 10 kHz 위는 measurement uncertainty를 고려해 unity 쪽으로 regularize
- UI에 sample rate, taps, partition, 구현 오차, PEQ 대비 개선, fallback 이유 표시
- 품질 또는 realtime gate를 통과하지 못하면 Standard IIR 유지
- “더 매끈하다”, “더 좋은 소리다” 같은 비측정 마케팅 주장을 하지 않음
- linear-phase FIR은 지원하지 않음

## 4. Phase 0: Measurement First

목표는 현재 엔진 품질을 수치화하고, 이후 DSP 변경의 safety net을 만드는 것이다.

### 작업

1. `bypass/flat/null` 테스트 추가
2. impulse response 기반 frequency response verification
3. Swift/TypeScript response parity fixture
4. [x] 20-band worst-case CPU benchmark (`AuralinkBenchmarks`)
5. preset switch/band drag transition click regression metric
6. clipping/underrun/resync history 저장

### Acceptance Criteria

- flat preset과 bypass path의 차이가 자동 테스트로 관리된다.
- offline response와 realtime impulse response가 허용 오차 내에서 일치한다.
- Swift `FrequencyResponse`와 MCP `validate.ts` response가 fixture 기반으로 일치한다.
- 20-band worst-case preset이 정해진 sample rate들에서 안정적으로 처리된다.
- transition click/pop을 수치로 비교할 수 있다.

## 5. Phase 1: Safer, Better IIR Path

목표는 기본 경로의 click/pop, headroom, edge case 안정성을 개선하는 것이다.

### 작업

1. coefficient smoothing보다 먼저 dual-cascade crossfade 검토
2. small parameter change에만 제한적 coefficient interpolation 검토
3. stable band identity 기반 state carry-over 개선
4. denormal 방어 추가
5. cascade ordering은 측정 후 결정
6. shelf Q/S 의미와 UI 문구 정리
7. true-peak meter를 limiter보다 먼저 추가

### Acceptance Criteria

- preset switch와 live band drag에서 pop/click regression이 감소한다.
- 기본 latency는 증가하지 않는다.
- high-Q, high-gain, low-frequency edge case에서 NaN/inf/unstable state가 없다.
- clipping risk와 실제 clipping telemetry가 더 잘 연결된다.

## 6. Phase 2: Correction Quality / AI Workflow

목표는 "좋은 필터"보다 "좋은 보정값을 안전하게 적용하는 workflow"를 강화하는 것이다.

### 작업

1. AutoEq baseline과 preference adjustment를 schema 또는 metadata로 분리
2. correction strength control 추가
3. measurement source confidence 추가
4. target curve blend/strength UX 추가
5. response graph에서 baseline/preference contribution 표시
6. MCP validation warning을 설명 가능하게 개선

### Acceptance Criteria

- 사용자가 측정 기반 baseline과 취향 조정을 구분할 수 있다.
- AI가 correction을 과하게 적용하는 빈도가 줄어든다.
- 측정 source가 불명확한 model match는 강한 correction으로 이어지지 않는다.
- preference tuning은 audition-first/save-on-like 정책을 유지한다.

## 7. Phase 3: Optional Advanced Filter Mode

목표는 FIR/convolution이 실제로 제품 가치가 있는지 검증하는 것이다.

### FIR이 가치 있는 경우

- measured correction을 더 정밀하게 맞춰야 한다.
- latency를 감수하는 음악 감상 모드가 명확히 있다.
- CPU/latency budget을 수치로 보여줄 수 있다.
- A/B에서 IIR보다 나은 결과가 반복적으로 나온다.

### FIR이 별 가치 없는 경우

- 사용자가 주로 영상, 게임, 회의 오디오를 듣는다.
- correction이 broad tonal shaping 위주다.
- latency와 pre-ringing 설명이 어렵다.
- CPU와 배터리 영향이 크다.

### 구현 작업

1. [x] AutoEq GraphicEQ ingestion + portable measured payload/provenance
2. [x] sample-rate-adaptive minimum-phase measured FIR designer/cache
3. [x] zero-added-block-latency direct-head + partitioned-tail convolver
4. [x] IIR/FIR mode switching and preset-update crossfade
5. [x] implementation-error + PEQ-improvement + headroom gates
6. [x] Release benchmark: 4 rates × 7 frame sizes × steady/transition + heap gate
7. [x] always-visible availability/status UI and legacy PEQ fallback

## 8. 파일별 작업 후보

### `Sources/AuralinkCore/DSP/Biquad.swift`

- coefficient validation
- pole stability check
- denormal state clamp
- shelf Q/S mapping 명확화
- filter type별 identity 조건 test
- coefficient calculation fixture test

### `Sources/AuralinkCore/DSP/EQProcessor.swift`

- active/inactive cascade 구조
- dual-cascade crossfade
- transition coalescing
- stable band identity 기반 state carry-over
- post-EQ sample peak meter
- true-peak estimator hook
- render-path allocation 검증

### `Sources/AuralinkCore/DSP/FrequencyResponse.swift`

- realtime biquad math와 parity 유지
- left/right-only band response 분리
- baseline/preference contribution 분리 계산
- response peak와 recommended preamp trace 제공
- TypeScript validator와 fixture 공유

### `Sources/AuralinkCore/Presets/PresetValidator.swift`

- response peak warning 개선
- excessive boost warning
- narrow high-Q treble warning
- low-frequency boost/headroom warning
- true-peak/clipping history 기반 warning
- baseline/preference 분리 검증

### `Sources/AuralinkApp/Audio/AudioRoutingEngine.swift`

- latency measurement hook
- ring fill history
- drift servo telemetry
- underrun/resync history
- preset transition marker
- output device/sample-rate 변경 시 DSP rebuild sequence 검증

### `Sources/AuralinkRT/auralink_rt.c`

- SPSC ring buffer stress test 강화
- no allocation/no lock invariant 문서화
- denormal/FTZ 가능성 검토
- render scratch preallocation 검증
- true-peak meter를 C로 내려야 하는지 판단

### `mcp-server/src/validate.ts`

- Swift response fixture와 parity test
- baseline/preference schema 지원
- correction strength 반영
- warning taxonomy 정리
- 설명 가능한 validation output 반환

### `mcp-server/src/autoeq.ts`

- alias matching 개선
- source priority policy
- confidence score
- measurement source metadata
- target curve/strength control
- 과한 correction clamp
- baseline preset 생성과 preference audition 분리

## 9. Sprint Plan

### Sprint 1: 증명 가능한 현재 상태 만들기

1. bypass/flat/null/impulse response test
2. Swift/TypeScript response parity fixture
3. [x] 20-band CPU benchmark
4. transition click regression metric
5. clipping/underrun/resync history 저장

결과물:

- 현재 엔진의 품질 리포트
- 릴리즈마다 비교 가능한 baseline
- 이후 DSP 변경의 safety net

### Sprint 2: IIR transition 안정화

1. stable band identity 추가
2. dual-cascade crossfade 구현
3. UI drag coalescing
4. state carry-over 정책 개선
5. denormal clamp
6. shelf Q/S UX 정리

### Sprint 3: headroom 신뢰도 개선

1. [x] true-peak estimator/meter
2. [x] clipping event history
3. [x] Safe Mode/auto-preamp 문구 정리
4. [x] loudness-matched A/B
5. [x] MCP validation warning 개선

### Sprint 4: correction quality

1. [x] AutoEq baseline/preference schema 분리
2. [x] correction strength
3. [x] source confidence
4. [x] target curve blend
5. [x] response graph에서 contribution 표시

### Sprint 5+: measured FIR

1. [x] dense measured-curve payload + AutoEq GraphicEQ cache
2. [x] sample-rate-adaptive minimum-phase designer/cache
3. [x] partitioned convolution with direct head
4. [x] IIR/FIR and preset-update crossfade
5. [x] response/headroom/CPU/allocation/transition gates
6. [x] opt-in product path with fail-closed Standard IIR fallback

## 10. 하지 말아야 할 것

- Linear-phase FIR을 기본 적용하지 않는다.
- "AI enhancer", exciter, stereo widener를 기본 음질 개선으로 포장하지 않는다.
- 전체 EQ path oversampling을 먼저 하지 않는다.
- limiter를 "음질 향상"으로 설명하지 않는다.
- AI가 자동으로 live apply/save하지 않는다.
- 측정 source가 불명확한 headphone correction을 강하게 적용하지 않는다.

## 11. 이번 주 시작할 3개

1. `bypass/flat/impulse/null` 테스트와 Swift/TypeScript parity fixture
2. preset switch/band drag transition click regression harness
3. post-EQ peak/true-peak/clipping history telemetry 설계

이 3개가 끝나면 이후의 DSP 개선을 느낌이 아니라 수치와 A/B로 판단할 수 있다.

## 12. 참고 링크

Pro Extended 응답에 포함된 참고 링크:

- [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/)
- [Leapwing Audio: Minimum Phase and Linear Phase Filters](https://leapwingaudio.com/blog/minimum-phase-and-linear-phase-filters/)
- [Partitioned convolution algorithms for real-time auralization](https://publications.rwth-aachen.de/record/466561/files/466561.pdf)
- [Ross Bencina: Real-time audio programming 101](https://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing)
- [ITU-R BS.1770-5](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I!!PDF-E.pdf)
- [AutoEq](https://github.com/jaakkopasanen/AutoEq)
