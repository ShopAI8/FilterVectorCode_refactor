# UNG Entry Route Performance Optimization Design

## Objective

Reduce cold-start and steady-state query time for the Amazon
`query_selected_recall_advantage` workload while preserving search results,
recall, and the meaning of the existing per-query CSV fields by default.

The baseline is the result set at:

`FilterVectorResult/Amazon/results/UNG_special_blocks_hybrid_bdeg64_bcross4_iroute1_small2048_large8192/query_selected_recall_advantage_1000_1000_20000`

Its measured search sweep takes 24.408 seconds. In steady state, approximately
24.8% of aggregate worker time is recorded as `OtherT_ms`; the main repeated
operation is merging LNG descendant and coverage Roaring bitmaps for an average
of 5,945.9 entry groups per query. The first Lsearch point is additionally
contaminated by construction of an approximately 1.298 GiB dense CPU ELS cache.

## Constraints

- Preserve existing user changes in the dirty worktree.
- The default optimized path must preserve returned IDs, distances, recall, and
  the semantics of `NumEntries`, `EntryGroupMatchedPoints`,
  `num_lng_descendants`, and entry-group coverage statistics.
- Optimizations that intentionally change search breadth or candidate ordering
  must be isolated behind explicit experimental settings and must not replace
  the default path unless recall is unchanged on the acceptance workload.
- Cold-start time and steady-state search time must be reported separately.
- An optimization with no reproducible benchmark benefit will not be retained.

## Phase 1: Semantics-Preserving Optimizations

### Cached entry-route result

Replace the current cache value of only `std::vector<IdxType> group_ids` with a
single immutable cached record containing:

- entry group IDs;
- number of LNG descendants;
- entry-group matched-point cardinality;
- entry-group total coverage;
- provider metadata required to reconstruct the per-query result.

The cache key remains the canonical query-label/provider key produced by
`make_entry_group_label_cache_key`. On a cache hit, the provider copies the
cached record into `EntryGroupProviderResult` and `QueryStats`; no Roaring
union is performed. On a miss, one thread computes the group IDs and route
statistics, publishes the complete record, and waiters reuse it. Publication
must be single-flight per key so concurrent duplicate queries do not repeat the
expensive calculation.

`prepare_entry_groups_for_execution` will no longer unconditionally invoke
`populate_entry_group_route_stats`. It will invoke it only when the provider
did not return valid cached route statistics. Providers that do not cache
results retain the existing computation and output semantics.

### CPU ELS warm-up and workload-aware rows

Add an explicit warm-up API invoked after index/query loading and before the
measured Lsearch loop when `cpu_bruteforce_els` is selected. The warm-up:

1. collects the canonical unique query-label sets;
2. collects the label universe used by those queries;
3. prepares ELS membership rows for that label universe in one group scan;
4. computes and caches every unique entry-route result outside measured time.

ELS membership rows become individually addressable by label instead of one
contiguous allocation for every index label. For the acceptance workload this
builds rows for 79 labels rather than 21,835. A label not present during warm-up
is supported through a thread-safe lazy row build; it must not be treated as an
absent label merely because it was not part of the warm-up universe.

The warm-up duration is reported separately. Benchmark search time starts only
after warm-up finishes.

### Reusable search execution resources

Introduce a reusable search execution context owned for the duration of the
Lsearch sweep. It contains the worker pool and reusable per-worker search
caches. Cache capacity grows to the largest requested Lsearch and never shrinks
during the sweep.

The existing single-call `search_hybrid` API remains available and creates a
temporary context for compatibility. The benchmark application uses the
explicit reusable context. All per-query visited/free-state structures are
cleared by generation/touched-entry mechanisms exactly as before.

### Binary special-edge sidecar

Prefer `special_edges.bin` when it exists and validates, falling back to CSV
when it is absent or invalid. Add a non-destructive conversion path that writes
a binary sidecar next to the existing CSV without deleting or replacing the
CSV. Loading reports which format was selected and how many edges were read.

The acceptance index is converted once before measuring startup. CSV and
binary edge counts must match.

## Phase 2: Isolated Search-Algorithm Experiments

Phase 2 begins only after Phase 1 correctness and performance results are
available.

### Entry-point breadth

Benchmark effective entry points per large group set at 4 (current behavior)
and 1. The value is an explicit runtime option. The value 1 is accepted only if
all tested Lsearch recall values are unchanged; otherwise 4 remains the
default.

### Candidate queue

Implement a bounded result max-heap plus expansion min-heap as an alternative
to ordered-vector insertion. The alternative must preserve deduplication,
free/regular state semantics, stable ID tie-breaking, and the stopping rule.
It remains experimental until result-ID equivalence and recall equivalence are
verified across the acceptance workload.

### Hardware settings

Benchmark 36, 72, 100, and 144 search threads, with and without NUMA
interleaving where available. Benchmark the existing AVX2 L2 kernel against
`avx2_fma4`. These are reported settings, not hard-coded defaults.

## Data Flow

For the optimized default path:

1. The application loads the query workload and index.
2. CPU ELS warm-up prepares only required label membership rows.
3. Each unique canonical query-label key is resolved once into a complete
   cached entry-route record.
4. The timed search retrieves that record and copies its statistics.
5. Search executes using resources retained across Lsearch values.
6. Per-query CSV output is generated with the same field meanings as before.

## Concurrency and Error Handling

- Cache records are immutable after publication.
- A per-key in-flight state prevents duplicate computation without holding a
  global mutex during Roaring unions.
- Failed computation does not publish a partial record; waiters receive the
  same failure or retry after the in-flight state is removed.
- Lazy ELS label-row construction is single-flight per label.
- Binary-sidecar validation failure logs a reason and falls back to CSV.
- Resource reuse is scoped to one index/search sweep and is not shared between
  concurrent independent searches.

## Testing Strategy

### Unit tests

- Equivalent label orderings map to one cache key and one cached route record.
- Concurrent requests for the same key execute the route-stat builder once.
- A cache hit restores all route statistics exactly.
- A non-caching provider still executes `populate_entry_group_route_stats`.
- Workload warm-up creates rows only for requested labels.
- An unseen label lazily creates a correct row.
- Reused search caches are clean between queries and can grow capacity.
- Binary and CSV special-edge loaders produce identical edge counts/content on
  a small fixture; invalid binary falls back to CSV.

### Integration and regression tests

- Existing `test_cpu_bruteforce_els`, special-block, and search tests pass.
- A small deterministic query fixture returns identical IDs, distances, and
  route statistics before and after cache hits.
- Repeated Lsearch calls using a reusable context match the compatibility API.

## Performance Acceptance

Run the Amazon `query_selected_recall_advantage` workload against the existing
baseline and record:

- index-load time;
- ELS warm-up time;
- batch wall time and QPS for every Lsearch;
- mean `Time_ms`, `core_search_time_ms`, `ELS_time_ms`, and `OtherT_ms`;
- recall for every Lsearch;
- cold and steady-state results separately.

Phase 1 is accepted when:

- every Lsearch recall equals the baseline at CSV precision;
- sampled query result IDs are identical, with full-result comparison where
  artifacts permit it;
- steady-state mean `OtherT_ms` is materially below the approximately 14 ms
  baseline;
- the first measured Lsearch no longer includes CPU ELS cache construction;
- no existing test regresses.

Phase 2 changes are accepted individually only when they improve batch wall
time or QPS and satisfy their stated result/recall equivalence requirement.

## Non-Goals

- Rebuilding the special-block graph topology.
- Changing the definition of ELS or LNG coverage.
- Removing diagnostic CSV fields from the default benchmark.
- Combining unrelated NaviX, ACORN, or GPU candidate-search refactors.
