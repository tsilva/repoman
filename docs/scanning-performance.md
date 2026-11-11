# Issue scanning performance

Issue checks and repository refreshes each keep up to four tasks active. Whenever one task finishes, the next begins without waiting for slower tasks in the original group. Findings still appear in catalog order, and incremental reports include each completed detector.

## Checker validity and refresh

Each checker has its own `validityPeriod`. Git status and inspection checks, plus published CI status, expire after five minutes. Local content, dependency, workflow, and configuration checks expire after one hour. Stale branches, old stashes, and published GitHub description checks expire after one day. Unavailable checks retry after at most five minutes.

Results, including clean results and unavailable reasons, are persisted with their original completion times in `~/Library/Application Support/RepoMan/inspection-cache.json`. The overview reads local Git status and restores reusable results from earlier scans. Reusing a result does not extend its expiry. A branch, upstream, remote, or checkout change can invalidate saved results.

Startup, folder changes, the periodic refresh, and **Refresh Overview** update local Git state, GitHub counts, and configured active-user readings. Ahead and behind counts remain provisional until a successful fetch verifies them.

Click the **Scan issues** magnifying glass in a repository’s issue list to fetch its remote-tracking refs and run its enabled checks. That action bypasses saved check results and published metadata caches. A fresh check is required to confirm that a prior finding is absent.

The inspection Git cache shares identical command results, including failures, for one inspection. Its global lock only protects cache lookup; each command has its own lock so independent commands can run concurrently. Cache keys include the repository, arguments, and accepted exit codes. New inspections create new caches, so subsequent checks read fresh state.

The snapshot reads working-tree changes and upstream divergence from one Git status command. It also gets the current branch from the branch listing when possible. The unfinished-operation check resolves all six Git marker paths together.

Content detectors compile their fixed regular expressions once. Merge-marker checks skip regex evaluation on ordinary source lines. File-size limits, binary sampling, path containment, redaction, and inspection availability rules remain in place.

## Scan phase timings

In macOS Console, include debug messages and filter for subsystem `com.tsilva.repoman` and category `Scanning`. RepoMan records discovery, overview and per-repository snapshots, fetches, post-fetch snapshots, and inspection time. Inspection includes saving the report to the cache. Timings omit repository paths and contents. Per-repository durations overlap, so their sum can exceed folder elapsed time.

## Fleet benchmark

On November 3, 2026, two optimized builds ran the desktop scan scheduler on the same 24 synthetic checkouts. Eighteen fetched from a local bare remote during forced refresh. Both builds used the same phase instrumentation. Five paired trials alternated which build ran first. Warm reopen started in a fresh process from a copy of the same cache. Routine refresh edited two tracked READMEs and made their link checks due. Forced refresh scanned every checkout with the same edits present.

| Scan mode | Median before | Median after |
| --- | ---: | ---: |
| Warm reopen | 9.37 s | 7.91 s |
| Routine refresh | 1.03 s | 1.19 s |
| Forced Refresh All | 15.62 s | 15.63 s |

The median startup snapshot pass fell from 4.29 s to 2.40 s. Inspection times varied across trials. Each pair returned identical findings and coverage across all 1,272 checker results per mode, including partial, unavailable, skipped, and inapplicable checks. These timings cover the scheduler and local Git transport on this fixture.

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

GitHub star and fork counts use a separate persistent cache shared by clones of the same GitHub repository. Known counts appear as soon as the local scan identifies the remote. Counts become due for refresh after 24 hours; the app gathers newly discovered remotes briefly and queries up to 50 at a time through the existing GitHub CLI login. One batch runs at a time in the background, independently of inspection and manual Git refresh. Failed lookups keep the last known value and wait ten minutes before retrying.

Run the native UI benchmark on macOS with Xcode installed:

```sh
Tools/benchmark-scrolling.sh
```

It snapshots and compiles the current sources, opens a temporary demo window with 300 repositories, moves the native viewport through two scrolling passes, and includes deferred layout and drawing in each timing. It also checks native selection, repeated scrollbar dragging, progress delivery, and completed-load cleanup. No Git scans or network requests run. Repeat the built benchmark with `.build/scrolling-benchmark/benchmark-scrolling --demo`.

On October 1, 2026, the idle 95th-percentile scroll time fell from 14.97 ms to 5.94 ms with the same fixture and viewport. Scrolling while publishing inspection progress measured 6.74 ms after batching. The benchmark checks against the display's frame budget, which was 8.33 ms at 120 Hz on this machine. These timings include a 1 ms run-loop interval and describe this fixture, not every repository collection or hardware configuration.
