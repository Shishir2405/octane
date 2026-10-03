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

STACK=2d53ed26775ff3fbe274ffc10830de7e1c9d4235
MAIN=950ef0b0bd80b87e8a2777b068dec65c6905eabb
PR639=73b22fd1185db202f218e1a7e9e230571ef01c30

pnpm --filter octane-tsrx-memowall-bench build >"$OUT/build-new-octane.log" 2>&1 || { tail -50 "$OUT/build-new-octane.log"; exit 1; }
pnpm --filter react-compiler-memowall-bench build >"$OUT/build-new-react.log" 2>&1 || { tail -50 "$OUT/build-new-react.log"; exit 1; }
old_tree $STACK octane-tsrx-memowall-bench
# Each octane build is served twice so the same-build spread is measured too.
serve benchmarks/memo-wall/octane-tsrx 5206
serve benchmarks/memo-wall/react-compiler 5226
serve /tmp/old-$STACK/benchmarks/memo-wall/octane-tsrx 6206
serve benchmarks/memo-wall/octane-tsrx 6216
serve /tmp/old-$STACK/benchmarks/memo-wall/octane-tsrx 6217
TARGETS='[
	{"name":"octane-tsrx","url":"http://localhost:5206/"},
	{"name":"react","url":"http://localhost:5226/"},
	{"name":"octane-tsrx-stack","url":"http://localhost:6206/"},
	{"name":"octane-tsrx-again","url":"http://localhost:6216/"},
	{"name":"octane-tsrx-stack-again","url":"http://localhost:6217/"}
]' BENCH_JSON="$OUT/memo-wall-ab.json" node benchmarks/memo-wall/run.mjs "$ITER" || echo "memo-wall A/B exited $?"
