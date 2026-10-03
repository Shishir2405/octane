#!/usr/bin/env bash
# Scratch A/B (never merged): memo-wall octane-tsrx built from this head, from
# its parent stack (main + #1655 + #1656), from main, and from #639, served at
# once next to this head's React Compiler fixture and driven by one paired run.
set -euo pipefail
ROOT=$PWD
OUT=$ROOT/benchmarks/results
mkdir -p "$OUT"
ITER=${AB_ITER:-15}

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

STACK=2d53ed2677a2d37e0f1fa9c7a71af70a28b2b1a8
MAIN=950ef0b0bdf3b6bc4c7d2c96fb3cbf6a77d1ee30
PR639=73b22fd1185db202f218e1a7e9e230571ef01c30

pnpm --filter octane-tsrx-memowall-bench build >"$OUT/build-new-octane.log" 2>&1 || { tail -50 "$OUT/build-new-octane.log"; exit 1; }
pnpm --filter react-compiler-memowall-bench build >"$OUT/build-new-react.log" 2>&1 || { tail -50 "$OUT/build-new-react.log"; exit 1; }
old_tree $STACK octane-tsrx-memowall-bench
old_tree $MAIN octane-tsrx-memowall-bench
old_tree $PR639 octane-tsrx-memowall-bench
serve benchmarks/memo-wall/octane-tsrx 5206
serve benchmarks/memo-wall/react-compiler 5226
serve /tmp/old-$STACK/benchmarks/memo-wall/octane-tsrx 6206
serve /tmp/old-$MAIN/benchmarks/memo-wall/octane-tsrx 6207
serve /tmp/old-$PR639/benchmarks/memo-wall/octane-tsrx 6208
TARGETS='[
	{"name":"octane-tsrx","url":"http://localhost:5206/"},
	{"name":"react","url":"http://localhost:5226/"},
	{"name":"octane-tsrx-stack","url":"http://localhost:6206/"},
	{"name":"octane-tsrx-main","url":"http://localhost:6207/"},
	{"name":"octane-tsrx-639","url":"http://localhost:6208/"}
]' BENCH_JSON="$OUT/memo-wall-ab.json" node benchmarks/memo-wall/run.mjs "$ITER" || echo "memo-wall A/B exited $?"
(cd benchmarks/memo-wall && BENCH_JSON="$OUT/memo-wall-survivor-work.json" node survivor-work.mjs) || echo "survivor-work exited $?"
