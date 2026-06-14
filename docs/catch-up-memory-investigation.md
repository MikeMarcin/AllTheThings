# Catch-Up Memory Investigation

Date: 2026-06-14

## Data Source

The live measurement used a copied snapshot from:

`~/Library/Application Support/AllTheThings/filename-index-v7.attindex`

The copied snapshot contained 982,862 records and 982,860 searchable results across:

- `/Users/jaeger/Desktop`
- `/Users/jaeger/Documents`
- `/Users/jaeger/Downloads`

The scoped catch-up run reconciled:

- `/Users/jaeger/Documents/GitHub`

Command:

```sh
ATT_PHASE_BENCH_LIVE_APP_NAME="AllTheThings" \
ATT_PHASE_BENCH_SCOPED_ROOTS="$HOME/Documents/GitHub" \
ATT_PHASE_BENCH_WAIT_FOR_OPTIMIZED=1 \
ATT_PHASE_BENCH_MEMORY_SAMPLE_MS=1000 \
swift test --filter RealRootPhaseTimingTests
```

Captured log:

`build/memory-investigation/live-phase-events-20260614-020321.log`

Follow-up captured log after streamed scoped merge and scoped records-only scan:

`build/memory-investigation/live-phase-streamed-scoped-20260614-1005.log`

## Result

The spike is real transient catch-up working set, not the footer's process-memory formatter.

| Phase | Elapsed | Physical footprint | RSS | Records | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| Copied mapped snapshot loaded | 19.8s | 123.9 MiB | 286.4 MiB | 982,862 | Baseline mapped load stayed small. |
| Previous mapped records materialized | 9.1s | 878.9 MiB | 1.02 GiB | 982,860 | Scoped catch-up calls `allRecords()` on the existing mapped store. |
| Scoped scan finished | 136.4s | 1.93 GiB | 2.13 GiB | 714,212 | Scan results are resident alongside the previous materialized snapshot. |
| Merge upserts applied | 137.6s | 2.25 GiB | 2.83 GiB | 982,877 | Whole-index merge dictionary has been built. |
| Heap store built | 139.6s | 2.40 GiB | 2.98 GiB | 982,877 | `HeapPagedRecordStore` adds another whole-index representation. |
| Mapped write in progress | 171.4s | 2.84 GiB | 3.42 GiB | 982,877 | Peak sampled between `optimize.mappedWrite.begin` and `.end`. |
| Name/component gram indexes built | 329.9s | 2.39 GiB | 3.87 GiB | 982,879 | Search structures keep the large transient set alive. |
| Search structures persisted | 370.3s | 2.39 GiB | 4.34 GiB | 982,879 | RSS continues upward due allocator and mapped-file retention. |
| Optimized wait finished | 371.1s | 127.0 MiB | 3.34 GiB | 982,877 | Physical footprint drops sharply; RSS remains retained. |

The operation peak was 2.84 GiB physical footprint and 3.42 GiB RSS. After catch-up finished, physical footprint dropped to 127.0 MiB. This classifies the observed footprint spike as transient. RSS remained high after completion, so Activity Monitor or `ps` RSS can overstate retained working memory after the actual footprint has fallen.

## Follow-Up Result

The scoped catch-up path now streams retained mapped rows plus scan upserts directly into the mapped package writer. It also skips the scoped scan `HeapPagedRecordStore` when no intermediate scan snapshots or checkpoints are needed.

| Run | Peak physical footprint | Peak RSS | Final physical footprint | Peak phase | Notes |
| --- | ---: | ---: | ---: | --- | --- |
| Before | 2.84 GiB | 3.42 GiB | 127.0 MiB | Mapped write | Held previous `[FileRecord]`, scan heap, merged dictionary, merged array, merged heap store, and writer package rows. |
| After | 2.02 GiB | 2.36 GiB | 123.6 MiB | Mapped write | Previous materialization and merged heap are gone; scoped scan heap is gone; peak remains in package preparation/writing. |

The follow-up reduced sampled peak physical footprint by 28.7%. The highest after-run sample was 2,173,143,560 bytes physical footprint at 115.9s, during mapped package write. Boundary telemetry around that run:

| Event | Elapsed | Physical footprint | RSS | Records | Store | Notes |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Scoped scan finished | 104.6s | 865.9 MiB | 1.18 GiB | 714,214 | none | Scoped scan collected records only; `heap_page_count=0`. |
| Stream source ready | 104.6s | 865.9 MiB | 1.18 GiB | 1,697,074 estimated | mapped | Retained previous rows are streamed from the mapped store; no `allRecords()` array. |
| Mapped write sampled peak | 115.9s | 2.02 GiB | 2.36 GiB | 1,697,074 estimated | mapped | Peak occurs inside package row preparation/write, between telemetry events. |
| Mapped write finished | 171.1s | 950.0 MiB | 1.50 GiB | 1,697,074 estimated | mapped | Writer transient structures have largely fallen. |
| Search structures persisted | 351.7s | 943.2 MiB | 2.59 GiB | 982,881 | mapped | RSS retention remains higher than physical footprint. |
| Reconcile job ended | 352.5s | 124.5 MiB | 2.06 GiB | 982,879 | mapped | Physical footprint returns near baseline. |

## Attribution

The original dominant source was avoidable duplicate materialization in scoped catch-up:

1. Materialize the existing mapped snapshot into `[FileRecord]`.
2. Keep the scoped scan store in memory.
3. Build a whole-index merge dictionary.
4. Materialize merged values as an array.
5. Build a `HeapPagedRecordStore`.
6. Write and load a mapped package.
7. Build name/component gram indexes and sort arrays before final publish.

The peak physical-footprint sample landed during mapped package writing, after the whole-index merge dictionary and heap store already existed. Name/component gram construction did not create the highest physical-footprint sample, but it extended the high-memory window and pushed RSS higher.

After the follow-up, items 1, 3, 4, and 5 are removed from scoped catch-up, and the scan heap from item 2 is also removed for scoped catch-up. The remaining peak is now the mapped package writer's own transient package table plus streaming path materialization and the scan-record dictionary. That is still a transient working set, but it is no longer caused by the previous whole-index reconcile merge.

## Interpretation

The original spike was expected with the previous scoped reconciliation algorithm, but it was not an inherent cost of catch-up. It was mostly duplicate whole-index representation during a scoped operation.

The implemented follow-up avoids whole-index `allRecords()` materialization during scoped catch-up and removes the merged heap store. It leaves one avoidable transient family: mapped package preparation still builds a whole-package `rowsByPath` table, virtual-directory set, child map, ordered rows, and lookup structures before the final mapped package can be installed. A further reduction would need to stream or shard mapped package construction itself.
