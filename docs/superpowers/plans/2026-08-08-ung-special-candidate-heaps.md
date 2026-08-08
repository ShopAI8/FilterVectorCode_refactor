# UNG Special-Block Candidate Heaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ordered-vector candidate insertion in special-block UNG search with reusable expansion and bounded-result heaps, preserve query behavior, and measure the result on Amazon `query_selected_recall_advantage`.

**Architecture:** Add a focused `SpecialCandidateQueue` that owns an expansion min-heap, a bounded result max-heap, and a small top-K max-heap for the existing early-stop input. Reuse one instance through each thread's `SearchCache`, integrate it only into `execute_special_block_ung_query`, and compare fresh pre-change and optimized runs written to isolated benchmark directories.

**Tech Stack:** C++17, STL heap algorithms, CMake/CTest, existing `search_UNG_index` benchmark application, CSV/awk result comparison.

## Global Constraints

- Preserve all pre-existing dirty-worktree edits; do not discard or overwrite unrelated changes.
- Modify only the special-block free-state query path; general `SearchQueue`, ordinary UNG, ACORN, FAVOR, graph construction, entry selection, and distance kernels are out of scope.
- Preserve ordering by `(distance, id, free)`, retained top-`Lsearch` semantics, visited timing, distance/stat accounting, approximate reranking, and optional early-stop inputs.
- Reuse heap allocations through `SearchCache`; do not add third-party dependencies.
- Write baseline and optimized outputs to separate directories; do not overwrite the user's existing result directory.
- Do not claim a speedup unless fresh A/B data shows reproducible benefit with recall within `1e-6` at every `Lsearch`.

---

### Task 1: Capture a fresh pre-change baseline

**Files:**
- Read: `FilterVectorResult/Amazon/results/UNG_special_blocks_hybrid_bdeg64_bcross4_iroute1_small2048_large8192/query_selected_recall_advantage_1000_1000_20000/others/Amazon_search_output.txt`
- Create artifact: `FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/`

**Interfaces:**
- Consumes: current Release `search_UNG_index`, existing Amazon index/query/ground-truth files.
- Produces: an immutable baseline log, summary CSV, and per-query CSV for all 20 `Lsearch` values.

- [ ] **Step 1: Verify the current binary and create isolated result directories**

Run:

```bash
test -x /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel/apps/search_UNG_index
mkdir -p /home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/results
cp /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel/apps/search_UNG_index \
  /home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/search_UNG_index_vector
```

Expected: executable check succeeds and no existing result directory is modified.

- [ ] **Step 2: Run the exact baseline workload**

Run the command recorded in the existing result log, changing only `--result_path_prefix` to the isolated baseline directory and setting the same method flags explicitly:

```bash
env UNG_SPECIAL_BLOCK_SEARCH=1 UNG_SPECIAL_EARLY_STOP=0 \
/home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel/apps/search_UNG_index \
  --data_type float --dataset Amazon --dist_fn L2 --num_threads 100 --K 10 --num_repeats 1 \
  --is_new_method true --force_use_alg 1 --is_idea2_available false --is_new_trie_method false \
  --is_rec_more_start false \
  --base_bin_file /home/dev/graphdb/FilterVectorData/Amazon/Amazon_base.bin \
  --query_bin_file /home/dev/graphdb/FilterVectorData/Amazon/query_selected_recall_advantage/Amazon_query.bin \
  --query_label_file /home/dev/graphdb/FilterVectorData/Amazon/query_selected_recall_advantage/Amazon_query_labels.txt \
  --query_group_id_file /home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/missing_query_source_groups.txt \
  --gt_file /home/dev/graphdb/FilterVectorResult/Amazon/GroundTruth/query_selected_recall_advantage/Amazon_gt_labels_containment.bin \
  --index_path_prefix /home/dev/graphdb/FilterVectorResult/Amazon/index/UNG_special_blocks_hybrid_bdeg64_bcross4_iroute1_small2048_large8192/index_files/ \
  --result_path_prefix /home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/results/ \
  --selector_model_prefix /home/dev/graphdb/FilterVectorResult/SelectModels --scenario containment \
  --num_entry_points 16 \
  --Lsearch 1000 2000 3000 4000 5000 6000 7000 8000 9000 10000 11000 12000 13000 14000 15000 16000 17000 18000 19000 20000 \
  --lsearch_start 1000 --lsearch_step 1000 --efs_start 10 --efs_step_slow 10 --efs_step_fast 10 \
  --lsearch_threshold 1000 --entry_group_provider cpu_bruteforce_els \
  --graph_search_backend neighbor_list --skip_query_features true --skip_bitmap_comparison true \
  > /home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/search.log 2>&1
```

Expected: exit 0; summary contains 20 data rows; query details contain 39,420 data rows.

- [ ] **Step 3: Validate baseline artifacts before changing production code**

Run:

```bash
test "$(($(wc -l < /home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/results/search_time_summary.csv)-1))" -eq 20
test "$(($(wc -l < /home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/baseline/results/query_details_repeat1.csv)-1))" -eq 39420
```

Expected: both checks succeed.

---

### Task 2: Build the heap candidate pool with TDD

**Files:**
- Create: `UNG/codes/include/ung_special_candidate_queue.h`
- Create: `UNG/codes/src/ung_special_candidate_queue.cpp`
- Create: `UNG/codes/test/test_special_candidate_queue.cpp`
- Modify: `UNG/codes/src/CMakeLists.txt`
- Modify: `UNG/codes/test/CMakeLists.txt`

**Interfaces:**
- Produces: `ANNS::SpecialSearchCandidate` and `ANNS::SpecialCandidateQueue`.
- `reset(capacity, top_k)` retains allocated storage; `initialize(candidates)` creates the initial top-L pool; `insert(id, distance, free)` conditionally retains a candidate; `pop_closest_unexpanded(out)` returns the closest active candidate; `peek_two_unexpanded(first, second)` supplies early-stop inputs; `kth_distance()` returns the retained Kth distance; `sorted_results()` materializes the active pool.

- [ ] **Step 1: Write the failing real-component test**

Create `test_special_candidate_queue.cpp` with an `expect` helper and literal fixtures. The break it catches is a queue that evicts the wrong tie, expands an evicted entry, drops an expanded result, or fails to reprioritize a newly discovered closer entry.

```cpp
#include "ung_special_candidate_queue.h"

#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
void expect(bool condition, const char *message) {
   if (!condition) {
      std::cerr << "FAILED: " << message << '\n';
      std::exit(1);
   }
}
}

int main() {
   ANNS::SpecialCandidateQueue queue;
   queue.reset(3, 2);
   queue.initialize({{9, 9.0f, false}, {3, 3.0f, false},
                     {5, 5.0f, true}, {1, 1.0f, false}});

   auto retained = queue.sorted_results();
   expect(retained.size() == 3, "initialization must retain capacity candidates");
   expect(retained[0].id == 1 && retained[1].id == 3 && retained[2].id == 5,
          "initialization must retain exact top-L order");
   expect(queue.kth_distance() == 3.0f, "top-K heap must expose Kth distance");

   ANNS::SpecialSearchCandidate current;
   expect(queue.pop_closest_unexpanded(current) && current.id == 1,
          "closest retained candidate must expand first");
   expect(queue.insert(2, 2.0f, false), "closer candidate must enter retained pool");
   expect(queue.pop_closest_unexpanded(current) && current.id == 2,
          "new closer candidate must become the next expansion");

   retained = queue.sorted_results();
   expect(retained[0].id == 1 && retained[1].id == 2 && retained[2].id == 3,
          "expanded candidate must remain while old worst candidate is evicted");
   expect(queue.pop_closest_unexpanded(current) && current.id == 3,
          "active unexpanded candidate must be returned");
   expect(!queue.pop_closest_unexpanded(current),
          "evicted candidates must be skipped in the expansion heap");

   queue.reset(4, 2);
   queue.initialize({{10, 4.0f, false}, {7, 4.0f, true},
                     {8, 4.0f, true}, {8, 4.0f, false}});
   retained = queue.sorted_results();
   expect(retained[0].id == 7 && retained[0].free &&
          retained[1].id == 8 && !retained[1].free &&
          retained[2].id == 8 && retained[2].free && retained[3].id == 10,
          "equal distances must use id then free tie ordering");
   float first = 0.0f;
   float second = 0.0f;
   expect(queue.peek_two_unexpanded(first, second) && first == 4.0f && second == 4.0f,
          "two closest active distances must be available for early stop");

   queue.reset(0, 0);
   expect(!queue.insert(1, 1.0f, false) && queue.sorted_results().empty(),
          "zero capacity must remain empty");
   std::cout << "special candidate queue checks passed\n";
}
```

Register `test_special_candidate_queue` in `codes/test/CMakeLists.txt`, but do not create the production header yet.

- [ ] **Step 2: Configure and verify RED**

Run:

```bash
cmake -S /home/dev/graphdb/FilterVectorCode_refactor/UNG/codes -B /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel -DCMAKE_BUILD_TYPE=Release
cmake --build /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel -j16 --target test_special_candidate_queue
```

Expected: compilation fails because `ung_special_candidate_queue.h` does not exist. A missing-header failure proves the new test is exercising the new component.

- [ ] **Step 3: Implement the minimal queue**

Define:

```cpp
struct SpecialSearchCandidate {
   IdxType id = 0;
   float distance = 0.0f;
   bool free = false;
};

class SpecialCandidateQueue {
public:
   void reset(size_t capacity, size_t top_k);
   void initialize(std::vector<SpecialSearchCandidate> candidates);
   bool insert(IdxType id, float distance, bool free);
   bool has_unexpanded();
   bool pop_closest_unexpanded(SpecialSearchCandidate &candidate);
   bool peek_two_unexpanded(float &first, float &second);
   float kth_distance() const;
   size_t size() const;
   std::vector<SpecialSearchCandidate> sorted_results() const;
};
```

Internally store `{candidate, token}` heap entries, an `active_` byte vector, and three reusable vectors. Use `std::push_heap`, `std::pop_heap`, and `std::make_heap` with one canonical `(distance, id, free)` comparator. The result and top-K heaps put the worst item first; the expansion heap puts the best item first. Mark an evicted result token inactive and discard inactive expansion entries lazily. Popping from the expansion heap must not deactivate the candidate because expanded candidates remain retained results.

Add `ung_special_candidate_queue.cpp` to `CPP_SOURCES` in `codes/src/CMakeLists.txt`.

- [ ] **Step 4: Verify GREEN and mutation-sensitive cases**

Run:

```bash
cmake --build /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel -j16 --target test_special_candidate_queue
ctest --test-dir /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel --output-on-failure -R '^special_candidate_queue$'
```

Expected: one test passes. Confirm that reversing the result-heap comparator or omitting active-token checks makes at least one literal fixture fail, then restore the correct implementation and rerun GREEN.

---

### Task 3: Integrate the reusable queue into special-block search

**Files:**
- Modify: `UNG/codes/include/search_cache.h`
- Modify: `UNG/codes/src/uni_nav_graph_search_backend.cpp`
- Test: `UNG/codes/test/test_special_candidate_queue.cpp`

**Interfaces:**
- Consumes: `SpecialCandidateQueue` from Task 2.
- Produces: special-block search with O(log `Lsearch`) hot-path insertion and O(`Lsearch` log `Lsearch`) final materialization instead of O(`Lsearch`) movement per accepted neighbor.

- [ ] **Step 1: Add the queue to per-thread reusable search state**

Include `ung_special_candidate_queue.h` from `search_cache.h` and add:

```cpp
SpecialCandidateQueue special_candidate_queue;
```

No other cache fields or lifecycle behavior change.

- [ ] **Step 2: Replace ordered-vector initialization and insertion**

In `execute_special_block_ung_query`:

- remove the local `SpecialCandidate`, `less_candidate`, `insert_candidate`, ordered `queue`, and `cur_unexpanded` definitions;
- bind `auto &candidate_queue = search_cache->special_candidate_queue;` and call `reset(runtime.Lsearch, runtime.K)`;
- score the same entry points into `std::vector<SpecialSearchCandidate>`;
- call `initialize(std::move(initial_candidates))`;
- preserve `comparisons = candidate_queue.size()` and all existing detail-stat updates;
- in `visit_neighbor` and GPU-batch insertion, call `candidate_queue.insert(...)` after the same visited marking and distance calculation, while continuing to increment comparisons and statistics exactly as before.

- [ ] **Step 3: Preserve expansion, early-stop, and final-result semantics**

Drive the loop with:

```cpp
SpecialSearchCandidate cur;
while (candidate_queue.has_unexpanded()) {
   float best_unexpanded = 0.0f;
   float second_unexpanded = 0.0f;
   if (runtime.special_block_early_stop && runtime.K > 0 &&
       candidate_queue.size() >= static_cast<size_t>(runtime.K) &&
       candidate_queue.peek_two_unexpanded(best_unexpanded, second_unexpanded) &&
       should_stop_special_block_search(true, candidate_queue.size(), runtime.K,
                                        best_unexpanded, second_unexpanded,
                                        candidate_queue.kth_distance(),
                                        stats.num_nodes_visited, early_stop_min_nodes))
      break;
   if (!candidate_queue.pop_closest_unexpanded(cur))
      break;
   // Existing edge traversal remains unchanged.
}
```

Materialize `std::vector<SpecialSearchCandidate> final_candidates = candidate_queue.sorted_results()` once after the core timer. For exact scoring, insert the first `K`. For approximate scoring, compute exact distances for this same active top-L set, select/sort exactly as before, and insert the first `K`.

- [ ] **Step 4: Build and run focused plus existing tests**

Run:

```bash
cmake --build /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel -j16 --target search_UNG_index test_special_candidate_queue
ctest --test-dir /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel --output-on-failure
```

Expected: Release executable builds and all registered tests pass with zero failures.

- [ ] **Step 5: Inspect the focused diff**

Run:

```bash
git diff --check -- UNG/codes/include/ung_special_candidate_queue.h UNG/codes/src/ung_special_candidate_queue.cpp UNG/codes/test/test_special_candidate_queue.cpp UNG/codes/include/search_cache.h UNG/codes/src/uni_nav_graph_search_backend.cpp UNG/codes/src/CMakeLists.txt UNG/codes/test/CMakeLists.txt
git diff --stat -- UNG/codes/include/ung_special_candidate_queue.h UNG/codes/src/ung_special_candidate_queue.cpp UNG/codes/test/test_special_candidate_queue.cpp UNG/codes/include/search_cache.h UNG/codes/src/uni_nav_graph_search_backend.cpp UNG/codes/src/CMakeLists.txt UNG/codes/test/CMakeLists.txt
```

Expected: no whitespace errors; no files outside the declared scope appear.

---

### Task 4: Run optimized Amazon benchmark and compare behavior

**Files:**
- Create artifact: `FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808/heap/`
- Read: baseline and heap `search_time_summary.csv` and `query_details_repeat1.csv`.

**Interfaces:**
- Consumes: optimized Release executable and Task 1 baseline.
- Produces: per-L latency/recall comparison and behavior-equivalence evidence.

- [ ] **Step 1: Run the optimized workload**

Repeat Task 1's command with only these output substitutions:

```text
baseline/results/  -> heap/results/
baseline/search.log -> heap/search.log
```

Expected: exit 0; optimized summary contains 20 rows; query details contain 39,420 rows.

- [ ] **Step 2: Check recall and work-count equivalence**

Use CSV column names rather than hard-coded positions to compare baseline and heap output. Assert for each `(Lsearch, QueryID)`:

- absolute recall difference is at most `1e-6`;
- `DistanceCalcs` matches exactly;
- `VisitedNodes` matches exactly;
- result row counts and key sets match.

If a mismatch occurs, stop performance interpretation and identify the first differing query and Lsearch.

Run this read-only comparison:

```bash
python3 - <<'PY'
import csv
from pathlib import Path

root = Path('/home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808')
def load(name):
    path = root / name / 'results/query_details_repeat1.csv'
    with path.open(newline='') as stream:
        return {(int(r['Lsearch']), int(r['QueryID'])): r for r in csv.DictReader(stream)}

baseline = load('baseline')
heap = load('heap')
if baseline.keys() != heap.keys():
    raise SystemExit(f'key mismatch: baseline={len(baseline)} heap={len(heap)}')
for key in sorted(baseline):
    b, h = baseline[key], heap[key]
    if abs(float(b['Recall']) - float(h['Recall'])) > 1e-6:
        raise SystemExit(f'recall mismatch at {key}: {b["Recall"]} != {h["Recall"]}')
    if int(float(b['DistCalcs'])) != int(float(h['DistCalcs'])):
        raise SystemExit(f'DistCalcs mismatch at {key}: {b["DistCalcs"]} != {h["DistCalcs"]}')
    if int(float(b['NumNodeVisited'])) != int(float(h['NumNodeVisited'])):
        raise SystemExit(f'NumNodeVisited mismatch at {key}: {b["NumNodeVisited"]} != {h["NumNodeVisited"]}')
print(f'equivalent rows: {len(baseline)}')
PY
```

Expected: `equivalent rows: 39420`.

- [ ] **Step 3: Produce the latency table**

For every Lsearch report:

```text
Lsearch | baseline wall ms | heap wall ms | wall speedup | baseline mean Core ms | heap mean Core ms | Core speedup | baseline recall | heap recall
```

Also report geometric-mean speedup for all 20 points and separately for `Lsearch >= 10000`. Do not average recall across Lsearch values when deciding equivalence.

Run:

```bash
python3 - <<'PY'
import csv, math
from collections import defaultdict
from pathlib import Path

root = Path('/home/dev/graphdb/FilterVectorResult/Amazon/benchmarks/ung_candidate_heaps_20260808')
def summary(name):
    path = root / name / 'results/search_time_summary.csv'
    with path.open(newline='') as stream:
        return {int(r['Lsearch']): r for r in csv.DictReader(stream)}
def core_means(name):
    path = root / name / 'results/query_details_repeat1.csv'
    total, count = defaultdict(float), defaultdict(int)
    with path.open(newline='') as stream:
        for row in csv.DictReader(stream):
            lsearch = int(row['Lsearch'])
            total[lsearch] += float(row['core_search_time_ms'])
            count[lsearch] += 1
    return {l: total[l] / count[l] for l in total}

b_summary, h_summary = summary('baseline'), summary('heap')
b_core, h_core = core_means('baseline'), core_means('heap')
speedups, high_speedups = [], []
print('Lsearch,baseline_wall_ms,heap_wall_ms,wall_speedup,baseline_core_ms,heap_core_ms,core_speedup,baseline_recall,heap_recall')
for lsearch in sorted(b_summary):
    bw = float(b_summary[lsearch]['Average_Time_ms'])
    hw = float(h_summary[lsearch]['Average_Time_ms'])
    wall_speedup = bw / hw
    core_speedup = b_core[lsearch] / h_core[lsearch]
    speedups.append(wall_speedup)
    if lsearch >= 10000:
        high_speedups.append(wall_speedup)
    print(f'{lsearch},{bw:.3f},{hw:.3f},{wall_speedup:.4f},{b_core[lsearch]:.3f},{h_core[lsearch]:.3f},{core_speedup:.4f},{float(b_summary[lsearch]["Average_Recall"]):.6f},{float(h_summary[lsearch]["Average_Recall"]):.6f}')
gmean = lambda values: math.exp(sum(math.log(v) for v in values) / len(values))
print(f'all_wall_geomean_speedup={gmean(speedups):.4f}')
print(f'high_L_wall_geomean_speedup={gmean(high_speedups):.4f}')
PY
```

- [ ] **Step 4: Classify the measured effect conservatively**

If all-20 or high-L geometric-mean speedup is below `1.05x`, or individual points change sign, classify the result as inconclusive rather than a successful optimization. The preserved `baseline/search_UNG_index_vector` remains available for follow-up repeated trials without modifying source state.

---

### Task 5: Final verification and handoff

**Files:**
- Read: all focused source/test diffs and benchmark artifacts.
- Do not modify unrelated files.

**Interfaces:**
- Produces: an evidence-backed conclusion and exact local file links.

- [ ] **Step 1: Run fresh final verification**

Run:

```bash
cmake --build /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel -j16 --target search_UNG_index test_special_candidate_queue
ctest --test-dir /home/dev/graphdb/FilterVectorCode_refactor/build_ung_rel --output-on-failure
git diff --check -- UNG/codes/include/ung_special_candidate_queue.h UNG/codes/src/ung_special_candidate_queue.cpp UNG/codes/test/test_special_candidate_queue.cpp UNG/codes/include/search_cache.h UNG/codes/src/uni_nav_graph_search_backend.cpp UNG/codes/src/CMakeLists.txt UNG/codes/test/CMakeLists.txt
```

Expected: build exits 0, CTest reports zero failures, and diff check reports no errors.

- [ ] **Step 2: Re-read acceptance criteria against evidence**

Confirm tests, Release build, 20-point recall tolerance, exact work-count comparison, and measured timing. If any condition fails, state the failure and either debug it or retain the pre-change implementation.

- [ ] **Step 3: Report outcome**

Provide:

- changed source and test files;
- focused and full test counts;
- the per-L A/B table plus geometric-mean speedups;
- recall/work-count equivalence or exact mismatches;
- whether the heap implementation is retained;
- links to baseline and optimized CSV artifacts.
