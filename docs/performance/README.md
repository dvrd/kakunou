# SQLite performance experiment log

**November 25–26, 2026.** Kakunou matched odin-sqlite-strict on the tested 50,000-row integer scan after changing which mutex it holds. Strict retained a small lead on prepared point lookups. Locking explains part of that lead. The experiments below distinguish the measured costs from the outstanding hypotheses.

## Reading the measurements

The Odin comparisons used optimized macOS builds (`-o:speed`), in-memory databases and system SQLite 3.54.0. The Strict checkout was `4418e23`. Its local binding linked the same system SQLite as Kakunou. Later comparisons explicitly enabled `FULLMUTEX` on both sides. The initial insert survey included library defaults. The operation lock is an additional recursive lock around a compound operation. [Strict source](https://github.com/sdicker8/odin-sqlite-strict/tree/4418e23ec1bba730cfc16ed1e7fd2361c6d5d616)

Times denote elapsed milliseconds for a complete workload. The scan materialized the rows and checked their count and sum. Point lookups checked their result or accumulated sum. Write fixtures verified the committed result. Most runs interleaved or rotated paths after warmup. Paired percentages use the median of within-round ratios. Run-to-run ranges below describe repetitions on one machine. Absolute times and ratios from different executables can vary with load and code generation.

## What changed and why

| Experiment and revision | Result | Decision |
|---|---|---|
| Initial survey of 50,000 inserts | Median one-shot / reused times were 78.93 / 34.03 for Kakunou, 67.68 / 24.34 for Strict, 73.93 / 24.61 for rusqlite 0.39.0 and 75.54 / 27.46 for rusqlite with full mutex. Defaults differed. | Match SQLite threading flags and statement lifetimes in subsequent comparisons. |
| Batch inserts, `a89ef82` | In a later interleaved comparison, one-shot, manual reuse and 256-row batches took 75.10, 33.27 and 28.36 respectively. Strict's reused loop took 24.43. | Ship `insert_many`. |
| Early wrapper controls | A 24-byte diagnostic prototype reduced the early scan from 11.64 to 8.32. Direct integer reads took 5.15. One-shot insert controls took 71.28 normally, 71.01 without the outer lock and 67.38 with the write-shape check also bypassed. | Keep full diagnostics and the check that prevents a write with returning rows from executing. Investigate the scan independently. |
| Integer reader, `51747af` | For runtime-selected decoders, required reads improved from 7.08 to 5.78 and optional reads from 6.55 to 5.73. Fixed required reads regressed from 5.53 to 6.01 and from 4.71 to 5.24 in a repeat. Two release copies gave 5.04 and 4.99. | The runtime-decoder result alone was insufficient. Direct and nested readers, output parameters, compile-time specialization, cold helpers and forced inlining failed to resolve the fixed-decoder regression consistently. |
| Scan locking, `25301ab` | Kakunou's scan took 5.24 with its outer native lock and 2.79 without it. Strict took 2.79 ordinarily and 5.16 with the same lock added. A repeat gave 5.63 / 3.02 and 3.01 / 5.59. Keeping the lock and bypassing Kakunou's decoder moved 5.24 to 5.21. A separate mutex around Strict cost 2.78 versus 2.82 ordinarily and 5.13 using the native lock. | Ship a separate recursive operation lock. Preserve SQLite serialization and transaction ownership. The raw-decoder and append controls did not explain the scan gap. |
| Verified scan after integration, `9aabce8` | Release / candidate / Strict took 5.62 / 3.22 / 3.26 in autocommit and 5.59 / 3.22 / 3.25 inside a read transaction. Adding the native lock around Strict point queries previously moved 12.46 to 13.01 for 10,000 lookups and 32.63 to 32.64 for 25 aggregates. | Scope the parity claim to integer scans on the tested build. |
| Other operations, `9aabce8` | Across 16 pairs, Kakunou / Strict elapsed-time ratios were 1.00 for batched inserts, 1.06 for one-shot inserts, 1.10 for indexed lookups, 1.07 for updates, 1.09 for deletes, 1.03 for sums and 1.06 for empty immediate transactions. Writes used an in-memory transaction. | Prioritize repeated preparation. A matched 10,000-lookup control went from 12.90 to 3.88 with per-call locking retained. One outer lock took 3.69 and Strict reuse took 3.67. |
| Per-call lock and shape controls | Caching the mutex pointer saved 0.14–0.19 per 10,000 reused lookups in two runs. Bypassing the operation lock inside an already-owned transaction saved a paired median of 0.81 for 10,000 updates and 0.72 for deletes. Removing the write-shape check gave an inconsistent additional gain. | Cache the mutex on the prepared handle and keep per-execution locking. |
| Scoped prepared API, `9099217` | In the repository benchmark, one-shot / prepared times for 10,000 operations were 13.20 / 3.94 for lookups, 14.15 / 4.74 for updates and 10.70 / 4.43 for deletes. A separate prepared-to-prepared run gave Kakunou / Strict times of 3.99 / 3.66, 4.84 / 4.35 and 4.59 / 4.00 respectively. | Ship statement reuse, cached arity and mutex, inlining of prepared helpers, and clearing bindings after borrowing text or blobs. One-shot binding and empty-tail shortcuts showed small, inconsistent benefits. |
| Prepared attribution, `9099217` | In two randomized runs the lookup / update / delete gaps were 5.6–7.0%, 6.6–8.1% and 8.1–8.5%. Adding a lock to Strict and checking write shape per execution narrowed those gaps to 5.0–5.7%, 4.4–4.5% and 3.5–3.9%. Binding inlining helped the combined executable and mixed-value microbenchmark. Its advantage disappeared in separate application builds. | Treat binary layout and decoder selection as experimental variables. Keep the checked write path. |
| Decoder error storage, `972c97b` | An out-of-line decoder's assembly contained a 312-byte diagnostic copy. Isolated controls compared direct integer reads, small status returns, callbacks returning full errors and callbacks writing an error slot. The integrated helper writes the diagnostic into its caller's storage. Repository benchmark medians improved from 3.87–3.90 to 3.58–3.65 per 10,000 prepared lookups. For 50,000 lookups the new fixed decoder took 19.71–19.75, the runtime-selected decoder 20.32–20.46, and Strict's fixed loop 18.80–18.89. | Ship the internal error-slot change, preserving the public decoder signature and full errors. Forcing both the column reader and step helper inline could regress performance. |
| Remaining attribution, `972c97b` | Two randomized runs of 40,000 lookups gave Kakunou a 3.7–4.1% excess time. Adding an operation lock to Strict cost 1.7–1.9%. In separate application builds a one-integer shortcut narrowed a 7.3% gap to about 6%. Forced binder inlining gave no repeatable gain there. The separate builds also exercised two integers, eight integers and integer-plus-text parameters. | Keep the general binder. The lock contributes measurably. How much of the remaining gap comes from binding, decoder returns and per-call bookkeeping remains open. |
| Backup acquisition timeout, `48584fe` | With a 50 ms budget and a 400 ms native mutex hold, backup succeeded after 401 ms. After the fix it returned BUSY in 51–53 ms for both native-lock and operation-lock contention. The regression test verifies no destination was published and retry succeeds. | Ship nonblocking native mutex acquisition during client-data lookup. |

## Samples and reproduction

The compressed CSV contains 11,940 timing observations from 83 retained CSV files. Each row records the experiment series, original run name, sample index, named case and elapsed milliseconds. Sample indices can restart when the same executable was run in multiple blocks. The public-benchmark before/after summaries and the backup wall-clock probes were recorded separately in the table. Some early measurements survive only as summaries. The archive preserves observations, not every temporary prototype or its build environment. [Timing samples](samples-2026-11.csv.gz)

To examine a specific run, this example reproduces the medians for the final decoder candidate:

```python
import csv
import gzip
from collections import defaultdict
from statistics import median

times = defaultdict(list)
with gzip.open("docs/performance/samples-2026-11.csv.gz", "rt") as source:
    for row in csv.DictReader(source):
        if row["series"] == "decoder" and row["run"] == "final1":
            times[row["case"]].append(float(row["milliseconds"]))
for case, samples in times.items():
    print(case, len(samples), round(median(samples), 3))
```

| Series in the CSV | Finding or control to inspect |
|---|---|
| `initial-inserts`, `early-controls` | Defaults versus full mutex, one-shot versus reused inserts, compact errors, raw column reads and write-shape checks. Early case names use K for Kakunou, S or strict for the peer and tiny or small for the compact-error prototype. |
| `scan-investigation`, `operation-lock` | Reader variants, parity between two release copies, native lock swaps in `reverse1` and `reverse2`, independent lock in `gate`, and final fixed / transaction scans. |
| `operations`, `per-call-cost` | Seven-workload survey in `samples`, isolated preparation in `matched`, cached lock lookup, and per-write checks. |
| `prepared`, `prepared-attribution` | Prepared API alternatives, partial binding cleanup, checked one-shot variants, lock and shape controls, mixed binding, and separate-build repeats. In the attribution series, `sb` denotes the standalone baseline and `si` the forced-inline candidate. |
| `decoder` | `probe` compares callback paths, `abi` isolates error passing, and `check1/2` and `final1/2` compare separately built applications before and after the change. |
| `remaining-gap` | `a` and `b` are randomized combined-executable runs. `standalone-*` includes fixed lookup, Strict, and wider parameter controls. |

To measure the supported Kakunou APIs on another machine, run the following from the checkout at the revision of interest. These benchmarks verify their results and print medians. The peer comparisons above used separate diagnostic harnesses.

```sh
odin run tools/bench_insert -o:speed
odin run tools/bench_prepared -o:speed
```

For the next attribution experiment, first measure Strict binding the same parameter slice and dispatching by type. Then compare the two error-return conventions with identical validation, and toggle arity, reentry and borrowed-binding checks individually in benchmark copies. Record the source revisions, compiler and SQLite build, workload, sample counts, raw timings, and whether the result repeats in a separately built application.
