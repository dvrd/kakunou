# WAL and recovery qualification

Run `task reliability` to exercise four independent writer connections for one minute. Each transaction appends a numbered event and increments its writer's counter. The workload uses WAL, FULL synchronous writes, Kakunou's default busy timeout, and explicit passive checkpoints. Each backup reads a pinned snapshot while writers remain active. The harness copies the published file to a fresh path and runs SQLite integrity and foreign-key checks, verifies each writer's complete sequence, and compares the restored event count with the count read from the pinned snapshot. After joining the writers, it reconciles acknowledged commits, closes and reopens the live database, and restores a final backup.

To qualify a deployment, point TMPDIR at an existing directory on the destination volume. For example, this runs eight writers for ten minutes with 64 MiB of seed payload and a five-millisecond pause between transaction attempts.

```sh
TMPDIR=/path/on/deployment-volume task reliability -- \
  -define:SOAK_SECONDS=600 -define:SOAK_WRITERS=8 \
  -define:SOAK_SEED_MIB=64 -define:SOAK_PACE_MS=5
```

The harness prints its private work directory and removes it on success. Transaction p99 includes lock waits and excludes the configured pause. BUSY counts attempts that exhausted the connection's wait. Restore time includes copying the published file, opening it, checking the data, and closing it. Set latency and recovery targets for your workload before comparing timings.

## Local runs

Both runs used the local macOS arm64 temporary volume and Odin dev-2026-11 (54322e177), with a one-minute target. Seed size measures initial payload bytes.

| Writers | Seed MiB | Pause ms | Commits | BUSY / attempts | Transaction p99 ms | Verified snapshots during writes | Slowest concurrent restore ms | Final restore ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 16 | 10 | 21,562 | 0 / 21,562 | 4.276 | 52 | 321.125 | 101.980 |
| 8 | 32 | 5 | 80,038 | 0 / 80,038 | 8.985 | 44 | 300.702 | 236.891 |

All 44 passive checkpoints in the eight-writer run reported checkpointed frames. The four-writer run preceded the addition of the explicit foreign-key check and checkpoint activity counter. CI runs a three-second smoke workload on Linux and checks data invariants without a hardware-specific latency threshold.

The integration suite also forces SQLITE_FULL using a database page limit. It verifies that a partial transaction rolls back, the connection accepts a later write, and reopening preserves exactly the expected rows. Physical volume exhaustion, power loss, and deployment-specific recovery times require separate qualification.
