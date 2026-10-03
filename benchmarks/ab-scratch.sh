#!/usr/bin/env bash
# Scratch A/B (never merged): memo-wall octane-tsrx built from this head
# (restampCtxDeps stops at the first ancestor without memoInChain) and from its
# base, #1664's head. Each build is served twice, so the same-build spread is
# measured too, next to this head's React Compiler fixture, in one paired run.
# The deterministic survivor-work probe runs on both runtimes first.
set -euo pipefail
ROOT=$PWD
OUT=$ROOT/benchmarks/results
mkdir -p "$OUT"
ITER=${AB_ITER:-60}
BASE=6a2c4a7d9a0eba020d379b2ca724d2dc7f9cfe7d

wait_port() {
	for _ in $(seq 1 240); do
		curl -sf "http://localhost:$1/" >/dev/null && return 0
		sleep 0.5
	done
	echo "port $1 never came up"; cat "$OUT/serve-$1.log" || true; return 1
}
serve() {
	local dir=$1 port=$2; shift 2
	(cd "$dir" && setsid nohup pnpm exec vite preview --port "$port" --strictPort "$@" >"$OUT/serve-$port.log" 2>&1 &)
	wait_port "$port"
}
old_tree() {
	local sha=$1; shift
	git fetch --no-tags --depth=1 origin "$sha"
	git worktree add --detach "/tmp/old-$sha" "$sha"
	local args=()
	for f in "$@"; do args+=(--filter "$f..."); done
	(cd "/tmp/old-$sha" && pnpm install --frozen-lockfile --prefer-offline --ignore-scripts --filter octane-monorepo "${args[@]}") >"$OUT/install-$sha.log" 2>&1 || { tail -50 "$OUT/install-$sha.log"; return 1; }
	for f in "$@"; do (cd "/tmp/old-$sha" && pnpm --filter "$f" build) >"$OUT/build-old-$sha-$f.log" 2>&1 || { tail -50 "$OUT/build-old-$sha-$f.log"; return 1; }; done
}

pnpm --filter octane-tsrx-memowall-bench build >"$OUT/build-new-octane.log" 2>&1 || { tail -50 "$OUT/build-new-octane.log"; exit 1; }
pnpm --filter react-compiler-memowall-bench build >"$OUT/build-new-react.log" 2>&1 || { tail -50 "$OUT/build-new-react.log"; exit 1; }
old_tree $BASE octane-tsrx-memowall-bench

# Deterministic work: this head's probe over the base runtime, then this head's.
BENCH_JSON="$OUT/survivor-work-base.json" node benchmarks/memo-wall/survivor-work.mjs "/tmp/old-$BASE/packages/octane/src/runtime.ts" >/dev/null
BENCH_JSON="$OUT/survivor-work-head.json" node benchmarks/memo-wall/survivor-work.mjs >/dev/null
node -e '
const fs = require("fs");
for (const side of ["base", "head"]) {
	const r = JSON.parse(fs.readFileSync(process.argv[1] + "/survivor-work-" + side + ".json", "utf8"));
	console.log(side, JSON.stringify(r.targets[0].ops), r.targets[0].meta.semantic);
}' "$OUT"

serve benchmarks/memo-wall/octane-tsrx 5206
serve benchmarks/memo-wall/react-compiler 5226
serve /tmp/old-$BASE/benchmarks/memo-wall/octane-tsrx 6206
serve benchmarks/memo-wall/octane-tsrx 6216
serve /tmp/old-$BASE/benchmarks/memo-wall/octane-tsrx 6217
TARGETS='[
	{"name":"octane-tsrx","url":"http://localhost:5206/"},
	{"name":"react","url":"http://localhost:5226/"},
	{"name":"octane-tsrx-base","url":"http://localhost:6206/"},
	{"name":"octane-tsrx-again","url":"http://localhost:6216/"},
	{"name":"octane-tsrx-base-again","url":"http://localhost:6217/"}
]' BENCH_JSON="$OUT/memo-wall-ab.json" node benchmarks/memo-wall/run.mjs "$ITER" || echo "memo-wall A/B exited $?"
