# Issue scanning performance

Issue checks and repository refreshes each keep up to four tasks active. Whenever one task finishes, the next begins without waiting for slower tasks in the original group. Findings still appear in catalog order, and incremental reports include each completed detector.

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
