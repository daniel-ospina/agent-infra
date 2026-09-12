# missing-config fixture (#716)

Deliberately contains **no** `second-model.json`. The guard's authority for
`--live-dir <this dir>` is `<this dir>/second-model.json`; its absence must
fail **closed** (`exit 2` — the designation authority is gone), never read
green. Git cannot track an empty directory, hence this README.
