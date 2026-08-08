# UNG Special-Block Candidate Heaps Design

## Goal

Replace the special-block search hot-path ordered `vector::insert` candidate pool with a reusable expansion min-heap and bounded result max-heap, while preserving search results and recall and demonstrating the change on Amazon `query_selected_recall_advantage`.

## Scope

The change applies only to `UniNavGraph::execute_special_block_ung_query`. The general `SearchQueue`, ordinary UNG search, ACORN, FAVOR-block search, graph construction, entry-group selection, and distance kernels remain unchanged.

The current dirty worktree is authoritative. Existing unrelated edits must be preserved, and task changes must remain separable in the final diff.

## Current Behavior

Each candidate is ordered by `(distance, id, free)` and is unique per `(id, free)` state because the regular and free visited sets reject repeats. The ordered vector retains the best `Lsearch` candidates, including expanded candidates. A newly accepted candidate is inserted with binary search followed by an O(`Lsearch`) element move. The next candidate to expand is the closest retained unexpanded candidate.

Initial entry candidates are all scored, truncated to the best `Lsearch`, and sorted. Search results are the first `K` retained candidates. When enabled, special early stop compares the two closest unexpanded distances with the Kth result distance after the minimum visit budget has been met.

## Selected Architecture

Introduce a focused reusable candidate-pool component for special-block search:

- An expansion min-heap returns the closest active, unexpanded candidate.
- A bounded result max-heap retains the best `Lsearch` candidates and exposes the current worst retained candidate.
- Candidate records receive monotonically increasing tokens. When a result candidate is evicted, its token is marked inactive; stale expansion-heap entries are discarded lazily.
- Expanded candidates remain active in the bounded result heap, matching the current capacity semantics.
- A bounded top-K max-heap exposes the Kth result distance for the existing optional early-stop rule. Since `K <= Lsearch`, eviction from the Lsearch heap cannot invalidate an established top-K entry except when it is simultaneously replaced by a better candidate.
- Heap backing vectors live in `SearchCache` and are cleared without releasing capacity between queries.
- Final active results are sorted once by `(distance, id, free)` before writing `cur_result` or exact-distance reranking.

Initial entry processing scores all existing entry points exactly as today. It selects the same top `Lsearch` set, initializes the result and top-K heaps from that set, and builds the expansion heap without retaining stale entries for discarded initial candidates.

## Behavioral Invariants

- Candidate ordering and tie-breaking remain `(distance, id, free)`.
- The retained pool is exactly the best `Lsearch` candidates seen so far.
- A candidate removed from the retained pool is never expanded later.
- Expanded retained candidates continue to consume result capacity.
- Visited-state timing, distance-calculation accounting, special/free traversal rules, prefetching, GPU batch fallback, and query statistics retain their existing behavior.
- `Lsearch == 0`, empty entry sets, approximate-distance reranking, and optional early stop remain safe.
- No runtime dependency or third-party heap library is added.

## Component Boundary

The candidate-pool class exposes only operations needed by the search backend:

- reset with `Lsearch` and `K` while retaining allocated storage;
- initialize from scored entry candidates;
- conditionally insert a scored candidate;
- inspect and pop the closest active unexpanded candidate;
- inspect the next active unexpanded distance for early stop;
- inspect the Kth retained distance;
- materialize active retained candidates in sorted order.

The class owns ordering and heap bookkeeping. Graph traversal, visited sets, distance computation, and statistics remain in the search backend.

## Testing Strategy

Add a focused C++ test target that exercises the real candidate-pool implementation with hand-derived fixtures:

- insertion retains the best capacity candidates with exact tie ordering;
- an evicted unexpanded candidate is skipped rather than expanded;
- an expanded candidate remains in the result set and consumes capacity;
- a newly inserted closer candidate becomes the next expansion candidate;
- initialization produces the same retained and expansion order as a sorted-vector reference fixture;
- Kth distance and second-unexpanded inspection support the existing early-stop inputs;
- reset removes logical state but preserves safe reuse.

The test must be observed failing before implementation, then pass after the minimal implementation. Existing project tests and a Release build of the search executable must also pass.

## Benchmark Method

Run a fresh baseline from the current pre-change binary and a fresh optimized run on the same machine with the exact command recorded in the existing Amazon result log: 1,971 queries, 100 threads, `K=10`, one repeat, CPU brute-force ELS, neighbor-list graph backend, 16 configured entry points, and `Lsearch=1000..20000` in steps of 1000.

Write baseline and optimized outputs to separate result directories so the existing result is not overwritten. Keep index, queries, ground truth, environment flags, and command-line arguments identical. Record wall time, average recall, per-query core time, ELS time, other time, distance calculations, and visited nodes for every Lsearch.

## Acceptance Criteria

- Focused candidate-pool tests and the full relevant CTest suite pass.
- The optimized search executable builds in Release mode.
- Average recall at every Lsearch is identical to baseline within `1e-6` unless a per-query result comparison proves only equal-distance tie reordering; unexpected differences block acceptance.
- Distance-calculation and visited-node aggregates match baseline; unexpected differences are investigated before claiming equivalence.
- Median steady-state search time improves across the sweep, with special attention to `Lsearch >= 10000`. Results are reported even if the optimization is neutral or slower.
- If the heap implementation does not provide reproducible benefit, it is not presented as a successful optimization and the retained/reverted state is stated explicitly.

## Rollback

The pre-change executable and isolated baseline output remain available for comparison. Because the component is limited to the special-block query path, rollback consists of restoring that call site and removing the focused candidate-pool files without affecting prior entry-route, ELS-cache, or binary-edge work.
