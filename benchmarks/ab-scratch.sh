#!/usr/bin/env bash
# Scratch A/B (never merged): fixtures from the commit that set each guard,
# this head's fixtures, and this head's fixtures rebuilt with the pre-#983
# terser flags, all served at once and driven by this head's paired harness.
set -euo pipefail
ROOT=$PWD
OUT=$ROOT/benchmarks/results
mkdir -p "$OUT"
ITER=${AB_ITER:-9}

wait_port() {
	for _ in $(seq 1 240); do
		curl -sf "http://localhost:$1/" >/dev/null && return 0
		sleep 0.5
	done
	echo "port $1 never came up"; cat "$OUT/serve-$1.log" || true; return 1
}
# serve <dir> <port> [extra vite preview args...]
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
	for f in "$@"; do (cd "/tmp/old-$sha" && pnpm --filter "$f" build) >"$OUT/build-old-$f.log" 2>&1 || { tail -50 "$OUT/build-old-$f.log"; return 1; }; done
}
build_new() {
	local f=$1
	pnpm --filter "$f" build >"$OUT/build-new-$f.log" 2>&1 || { tail -50 "$OUT/build-new-$f.log"; return 1; }
	pnpm --filter "$f" exec vite build --config vite.alt.config.js >"$OUT/build-terser-$f.log" 2>&1 || { tail -50 "$OUT/build-terser-$f.log"; return 1; }
}

REORDER_OLD=73b22fd1185db202f218e1a7e9e230571ef01c30

# js-framework-reorder: octane-tsrx vs React. The alt build is the pre-#983
# terser build.
old_tree $REORDER_OLD octane-tsrx-jsbench react-jsbench
build_new octane-tsrx-jsbench
build_new react-jsbench
serve benchmarks/js-framework/octane-tsrx 5176
serve benchmarks/js-framework/react 5175
serve benchmarks/js-framework/octane-tsrx 6476 --config vite.alt.config.js
serve benchmarks/js-framework/react 6475 --config vite.alt.config.js
serve /tmp/old-$REORDER_OLD/benchmarks/js-framework/octane-tsrx 6376
serve /tmp/old-$REORDER_OLD/benchmarks/js-framework/react 6375
TARGETS='[
	{"name":"octane-tsrx","url":"http://localhost:5176/","ready":"#run"},
	{"name":"react","url":"http://localhost:5175/","ready":"#run"},
	{"name":"octane-tsrx-terser","url":"http://localhost:6476/","ready":"#run"},
	{"name":"react-terser","url":"http://localhost:6475/","ready":"#run"},
	{"name":"octane-tsrx-old","url":"http://localhost:6376/","ready":"#run"},
	{"name":"react-old","url":"http://localhost:6375/","ready":"#run"}
]' BENCH_JSON="$OUT/js-framework-reorder-ab.json" node benchmarks/js-framework/run-reorder.mjs "$ITER" || echo "reorder A/B exited $?"
