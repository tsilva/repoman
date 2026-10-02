# Issue scanning performance

Issue checks and repository refreshes each keep up to four tasks active. Whenever one task finishes, the next begins without waiting for slower tasks in the original group. Findings still appear in catalog order, and incremental reports include each completed detector.

## Checker validity and refresh

Each checker has its own `validityPeriod`. Git status and inspection checks, plus published CI status, expire after five minutes. Local content, dependency, workflow, and configuration checks expire after one hour. Stale branches, old stashes, and published GitHub description checks expire after one day. Unavailable checks retry after at most five minutes.

Results, including clean results and unavailable reasons, are persisted with their original completion times in `~/Library/Application Support/RepoMan/inspection-cache.json`. Startup reads a current repository snapshot but only executes missing or expired checkers. Reusing a result does not extend its expiry. Changing the branch, upstream, remote, or replacing the checkout invalidates its cached results. New checkers run automatically; unreadable or incompatible caches are rebuilt by inspection.

While the app is open, a scheduler checks for expired results every minute and inspects only repositories that need work. Startup and automatic scans fetch a repository's remote only when its remote Git checks need refreshing. Each repository runs the checker catalog once, after any fetch, rather than before and after fetching.

Refresh in the issue list forces every checker for the selected repository. Refresh in the repository list (or the Refresh All menu command) forces every checker for every discovered repository. These actions also bypass the underlying published-metadata cache. Busy repositories remain protected from concurrent inspection during repairs. Repair preflight and verification always inspect fresh state, and reused results cannot resolve repair conversations.

The inspection Git cache shares identical command results, including failures, for one inspection. Its global lock only protects cache lookup; each command has its own lock so independent commands can run concurrently. Cache keys include the repository, arguments, and accepted exit codes. New inspections create new caches, so repair verification still reads fresh state.

Content detectors compile their fixed regular expressions once. Merge-marker checks skip regex evaluation on ordinary source lines. File-size limits, binary sampling, path containment, redaction, and inspection availability rules remain in place.

## Reproducing local timings

From the repository root, build an optimized benchmark and pass the repository to inspect:

```sh
mkdir -p .build
swiftc -O -parse-as-library RepoManCore/*.swift Tools/BenchmarkInspection.swift -o .build/benchmark-inspection
.build/benchmark-inspection /path/to/repository
```

The benchmark performs three summary scans and prints snapshot and local inspection durations separately. It excludes remote fetching, CI status requests, and published GitHub description requests. It runs read-only detectors; it does not execute project scripts. Run against the same files before and after a change and compare medians.

On October 1, 2026, optimized before/after builds measured:

| Repository | Median local inspection before | After | Speedup |
| --- | ---: | ---: | ---: |
| RepoMan checkout | 0.919 s | 0.258 s | 3.6× |
| Synthetic repository: 16 tracked text files, 6,000 lines each | 10.726 s | 0.462 s | 23.2× |

Each synthetic file contained `let value = 42 // Ordinary source code to inspect.` followed by a newline, repeated 6,000 times. The files were staged in a new repository on `main`, with no commits or remote. Both versions returned four findings and no unavailable local checks. RepoMan returned four findings and three unavailable local checks in both versions. These measurements describe local inspection, not end-to-end refresh latency; fetches and GitHub response times depend on the network.

## Repository list scrolling

The sidebar uses an `NSTableView` with fixed 52-point rows and independently hosted SwiftUI row contents. AppKit reuses the row views and owns the themed scrollbar's tracking. Issue badges are calculated for visible rows, and unchanged row contents are retained when other repositories update.

Inspection progress is published in 100 ms batches. Each batch retains the latest cumulative report for each repository and loading token. Final scan results still apply immediately. Folder changes discard pending batches, and finished loading tokens cannot restore stale progress.

Run the native UI benchmark on macOS with Xcode installed:

```sh
Tools/benchmark-scrolling.sh
```

It snapshots and compiles the current sources, opens a temporary demo window with 300 repositories, moves the native viewport through two scrolling passes, and includes deferred layout and drawing in each timing. It also checks native selection, repeated scrollbar dragging, progress delivery, and completed-load cleanup. No Git scans or network requests run. Repeat the built benchmark with `.build/scrolling-benchmark/benchmark-scrolling --demo`.

On October 1, 2026, the idle 95th-percentile scroll time fell from 14.97 ms to 5.94 ms with the same fixture and viewport. Scrolling while publishing inspection progress measured 6.74 ms after batching. The benchmark checks against the display's frame budget, which was 8.33 ms at 120 Hz on this machine. These timings include a 1 ms run-loop interval and describe this fixture, not every repository collection or hardware configuration.
