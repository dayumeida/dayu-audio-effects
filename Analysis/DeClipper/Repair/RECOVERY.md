# ERA5 DeClipper 5.4.00 ARM64 repair reconstruction

This directory contains ordinary `llvm-objdump` / LLDB evidence and a C++ reconstruction. It is not REA-produced evidence: the requested REA provider/engine was unavailable in this environment. Runtime fixtures were captured while an ordinary AudioUnit host initialized and rendered the installed, unmodified trial AU. No license state, target instruction, target register, installation, or target control flow was modified.

## Recovered routines

| ARM64 routine | Reconstruction | Evidence |
| --- | --- | --- |
| `0x43348` | Burg reflection coefficients, AR polynomial, mean removal/restoration, FIR priming, direct-form II prediction | `../func-43348.asm`, `lpc-runtime-calls.json`, `lpc-comparison.json` |
| `0x43098` | Bidirectional prediction weights | `../func-43098.asm`, dual runtime fixtures |
| `0x2a4a8` | Per-region backward/forward prediction, cache backup/restore, weighting, magnitude fallback | `../func-2a4a8.asm`, `dual-runtime-calls.json`, `region-comparison.json` |
| `0x6aaf4` | Bessel spline secants and derivative estimates | `func-6aaf4.asm`, `spline-runtime-calls.json`, `region-comparison.json` |
| `0x2bf60` | Region scheduling, spline prefill, preliminary LPC passes, final LPC, status transitions | `../func-2bf60.asm`, `loop-runtime-*.json`, `loop-comparison-*.json` |

The main interface is `dayu::recovered::RepairLoop` in `RecoveredRepairLoop.hpp`. `prepare()` allocates; `process()` and `reset()` do not allocate or lock. It processes a planar double channel in place, preserving the rolling region statuses and per-channel LPC caches. It does not implement the detector, input/output queue, latency, gain, limiter, UI, or AU wrapper; those are owned by the parent investigation. Compile with `-ffp-contract=off`, without fast-math.

## Default 48 kHz configuration

The runtime object reports frame length 5224, LPC neighborhood 762, spline neighborhood 22, process limit 3265, active LPC order 100 in standard quality / 150 in high quality, allocated order 150, and cross-window region merge limit 435. The neighborhood/limit values scale from 700, 20, 3000, and 400 samples at 44.1 kHz respectively. Regions use inclusive start/end and statuses 1 detected, 2 spline-filled, 3 preliminary LPC, 4 final repair.

Quality 0 reuses the cached backward LPC during a cluster, with the first eligible preliminary region (or the first following a direct/small repair) refreshing it. Quality 1 re-estimates both directions in preliminary passes. Every final region pass re-estimates both directions; the second estimate is followed by restoration of the first-direction cache.

## Verification completed at 48 kHz

All full fixtures use the same four-second, stereo synthetic input from `../ERA5DSPProbe.mm`, including clean input, symmetric clipping, asymmetric clipping, and the return to clean input. The host renders 76 work windows. Processing type 1 has 58 nonempty windows; processing type 2 has 76.

| Type / quality | Channel windows | Double output comparisons | Result file |
| --- | ---: | ---: | --- |
| Type 1 / quality 0 | 116 | 605,984 | `loop-comparison-final-standard-full.json` |
| Type 1 / quality 1 | 116 | 605,984 | `loop-comparison-final-high-full.json` |
| Type 2 / quality 0 | 152 | 794,048 | `loop-comparison-final-type2-full.json` |
| Type 2 / quality 1 | 152 | 794,048 | `loop-comparison-final-type2-high-full.json` |

Each row has **zero differing output bits**, zero differences in all 151 stored polynomial values and every region status/start/end, and zero observed C++ `new` calls during processing. The final verification includes every optimization below, with a pause after every single work unit. `final-verification.json` summarizes 536 channel windows and 2,800,064 double output comparisons. These fixtures explicitly enable the observed heap-tail compatibility mode. Production defaults to the defined, safe LPC tail described below. Subroutine fixtures separately verify means, coefficients, reflections, prediction arrays, weights and spline slopes.

## Reference out-of-bounds behavior for long regions

The original LPC object's `+0x30` residual pointer has declared length 150 at `+0x38`. The filtering loop at `0x44558` nevertheless reads `predictLen` consecutive doubles. The region length can reach 435 at 48 kHz. Observed original allocations are 160 doubles apart:

| Relative residual index | Observed allocation/data |
| --- | --- |
| 0–149 | Residual buffer; active 100 coefficients then zeros |
| 150–159 | Allocator padding, observed zero |
| 160–309 | `+0x40` negative reversed AR coefficients |
| 310–319 | Allocator padding, observed zero |
| 320–469 | `+0x50` reversed context |

`lpc-long-runtime-calls.json` retains eight original 435-sample calls, full declared arrays, original addresses, and the extended read range. All eight extended tails exactly equal the named adjacent arrays. A conventional zero residual tail diverges from processing type 2 at work window 29; `loop-comparison-type2-full.json` and `loop-comparison-type2-high-full.json` preserve that initial failed comparison.

`RecoveredLPC.hpp` can reproduce the two observed adjacent arrays by bounded copies into a preallocated buffer, with explicit zero padding. This code performs no out-of-bounds access. `setReferenceHeapTail(true)` explicitly enables that evidence-only compatibility mode, forwarded by `DualPrediction` and `RepairLoop`. **The production default is false:** only the initial `order` residual values are valid and every later value is zero, as in defined AR extrapolation. This deliberately repairs the original undefined behavior. The parent investigation approved this boundary after observing different original type-2 standard output across separate normal AU processes.

This behavior depends on the reference allocator's layout, rather than a defined LPC algorithm. Prediction lengths above 150 already exceed the reference's declared residual length; above 160 they consume the next allocation. At the default merge bound (approximately `rate * 400 / 44100`), rates above approximately 16.5 kHz can exceed 150, and ordinary 44.1/48 kHz operation can consume both adjacent arrays. The compatibility mode uses zero beyond index 469 and does not model later heap allocations. The reconstruction must not claim arbitrary allocator-state equivalence from these fixtures.

At 96 kHz, `lpc-long-96k-runtime-calls.json` captures 870-sample predictions. For channel 0, residual indices 480–630 read its backup polynomial, 640–790 read the second channel's polynomial, and 800 onward read the second channel's reversed polynomial. The second channel's own residual-to-backup spacing is 608 instead of 480, showing an allocator page boundary. This makes arbitrary reconstruction of the original invalid read neither mathematical LPC nor portable behavior. The unmodified original AU's synthetic output saturates to 0 dB RMS in seconds 2 and 3 in both observed 96 kHz processes. `loop-runtime-type2-96k.json` retains the complete repair-window evidence. No further cross-page heap emulation is included in production.

## Deterministic bounded scheduling

`LPC::beginPredict()` / `stepPredict(units)` pause after a Burg order, polynomial order, FIR priming pass, or IIR sample. `DualPrediction::begin()` / `step()` schedule both directions. `RepairLoop::begin()` / `step(uint32_t units=1)` schedule region preparation and final repair; `busy()` reports completion and `cancel()` discards an unfinished job. The existing synchronous calls execute these same state machines to completion. Reset and prepare cancel pending predictions before touching their storage. Context views remain exclusive until completion or cancellation.

`RepairLoop::workUnitsUpperBound()` is computed from geometry/statuses without processing audio. It is exact when coefficients stay finite; invalid coefficients can select the constant-mean fallback and omit IIR units. Every final fixture's actual `step(1)` count is at or below the bound. Maximum counts per channel are 50,786 / 134,786 for type 1 standard / high, and 51,649 / 135,649 for type 2 standard / high. Buffering and deadlines belong to the parent stream scheduler, not to this per-window routine.

All three layers also provide `nextCost()`. Static `LPC::predictionCost()` and `DualPrediction::repairCost()` predict the same relative costs; `RepairLoop::estimatedCost()` caches a geometry estimate in `begin()`, using the same pass as the work-unit estimate. The cost of a 48 kHz / 762-context Burg order is approximately one:

| Stage | Relative cost |
| --- | --- |
| Burg order `m` | `(2*n-m-2)/1524` |
| Polynomial order `m` | `(m+1)/500` |
| FIR priming | `2+order²/3500` |
| IIR sample | `order/250` |
| LPC finish | `0.4+(n+count)/5000` |
| Dual setup/blend | `0.5+localLength/4000` |
| Spline region | `2+regionLength*0.01` |
| Other repair-loop work | `0.5` |

`weighted-cost-verification.json` compares the sum of `nextCost()` before every `step(1)` with the cached estimate for all 536 channel windows. The maximum relative underestimate is `2.7e-13`, due to floating summation; the occasional constant-mean fallback makes the estimate larger. Consumers must not impose a different cost floor without applying the same floor to the static estimate. In particular, clamping the polynomial's initial `0.002`–`0.048` costs to `0.05` creates a cumulative underestimate.

The final AddressSanitizer + UndefinedBehaviorSanitizer build ran the complete 152-channel-window type-2 high-quality fixture at `step(1)`, including explicitly enabled compatibility copies. It returned success, retained zero output differences, and produced zero stderr bytes (`loop-comparison-asan-final.json`, `asan-final-stderr.txt`).

## Exact hot-path optimizations

- `combinedDot()` fuses the three Burg dot products into one memory traversal using the current ARM64 vDSP's eight-vector FMA accumulation and reduction order. `vDSP-dot-disassembly.txt` preserves the observed system implementation. `MathProbe.cpp` checks 30,000 dot results over 10,000 random inputs of lengths 1–1600; every result is bit-identical. Its recorded microbenchmark reduced three dots from 25.306 ms to 9.378 ms over 100,000 repetitions.
- The forward/backward Burg updates share one NEON traversal, with eight samples per iteration. The rounded reciprocal multiply used by `vDSP_vsdivD`, then addition, then multiplication are preserved separately, including zero-coefficient NaN behavior. The arithmetic is not collapsed into a different Burg formula. A 1.6-million-value random check confirms the reciprocal multiplication matches vDSP division.
- The vector pointers are held outside the update loop. Each order clears only the newly exposed zero-tail element; the remaining tail was already cleared by the previous order. Polynomial reversal copies only the coefficients that can be nonzero at that order, while preserving all source values.
- A finite-state IIR with denominator leading coefficient 1 omits the numerator's zero products, preserving the signed-zero addition. Once a nonfinite state appears, the complete reference arithmetic path is used.

The parent observed the high-quality four-second stream decrease from approximately 2.74 s of CPU time to 1.27 s after the first three optimization stages, with peak work-window time near 50 ms before the final eight-sample unroll and polynomial-copy refinement. Standard quality met the parent's measured callback budgets at 44.1/48/96 kHz. High quality at 48 kHz is close to the callback budget, and sustained high quality at 96 kHz has not met that budget; time slicing alone cannot reduce total CPU requirements. Those measurements are parent stream evidence, not a promised host-wide deadline. The parent owns final timeline performance, cost-credit pacing, and additional fixed scheduling latency validation.

## Reproducing the comparisons

Run the normal AU host under the commands in `lldb-loop.commands`; environment `DAYU_CAPTURE_TAG` selects the evidence filename and `DAYU_CAPTURE_LIMIT=100` captures the full four-second input. Example arguments: `--render --quality 0 --ptype 1`. `generate-loop-fixtures.py TAG` converts the retained JSON to exact binary fixtures. Compile `LoopComparison.cpp` with Clang C++17, `-O2 -ffp-contract=off`, linking Accelerate; pass `loop-fixture-TAG.bin`. The test restores each observed input window and polynomial cache, calls the reconstructed routine, then compares full output, cache and region state.

## Remaining boundaries

Invalid/nonincreasing spline knots are rejected safely instead of reproducing the original exception/undefined behavior. Contexts too short for the LPC order are rejected safely. The reconstruction validates frame capacity and indices. These defensive boundaries do not affect the 48 kHz compatibility fixture results. Production deliberately differs from undefined original heap reads; source-exact behavior under every invalid input, allocator history, or host/sample-rate combination is not claimed.
