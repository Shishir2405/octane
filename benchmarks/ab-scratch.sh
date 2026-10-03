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
	pnpm --filter "$f" exec vite build --config vite.terser.config.js >"$OUT/build-terser-$f.log" 2>&1 || { tail -50 "$OUT/build-terser-$f.log"; return 1; }
}

MEMO_OLD=73b22fd1185db202f218e1a7e9e230571ef01c30
SVG_OLD=7a6fba3aef8a0bb1c9f5a01ca00bbcec0e4aa6f1

# memo-wall: octane-tsrx vs React Compiler.
old_tree $MEMO_OLD octane-tsrx-memowall-bench react-compiler-memowall-bench
build_new octane-tsrx-memowall-bench
build_new react-compiler-memowall-bench
serve benchmarks/memo-wall/octane-tsrx 5206
serve benchmarks/memo-wall/react-compiler 5226
serve benchmarks/memo-wall/octane-tsrx 6306 --config vite.terser.config.js
serve benchmarks/memo-wall/react-compiler 6326 --config vite.terser.config.js
serve /tmp/old-$MEMO_OLD/benchmarks/memo-wall/octane-tsrx 6206
serve /tmp/old-$MEMO_OLD/benchmarks/memo-wall/react-compiler 6226
TARGETS='[
	{"name":"octane-tsrx","url":"http://localhost:5206/"},
	{"name":"react","url":"http://localhost:5226/"},
	{"name":"octane-tsrx-terser","url":"http://localhost:6306/"},
	{"name":"react-terser","url":"http://localhost:6326/"},
	{"name":"octane-tsrx-old","url":"http://localhost:6206/"},
	{"name":"react-old","url":"http://localhost:6226/"}
]' BENCH_JSON="$OUT/memo-wall-ab.json" node benchmarks/memo-wall/run.mjs "$ITER" || echo "memo-wall A/B exited $?"

# svg-dashboard: octane-tsrx vs React (compiled).
old_tree $SVG_OLD octane-tsrx-svg-dashboard-bench react-svg-dashboard-bench
build_new octane-tsrx-svg-dashboard-bench
build_new react-svg-dashboard-bench
serve benchmarks/svg-dashboard/octane-tsrx 5302
serve benchmarks/svg-dashboard/react 5303
serve benchmarks/svg-dashboard/octane-tsrx 6402 --config vite.terser.config.js
serve benchmarks/svg-dashboard/react 6403 --config vite.terser.config.js
serve /tmp/old-$SVG_OLD/benchmarks/svg-dashboard/octane-tsrx 6302
serve /tmp/old-$SVG_OLD/benchmarks/svg-dashboard/react 6303
TARGETS='[
	{"name":"octane-tsrx","url":"http://localhost:5302/"},
	{"name":"react","url":"http://localhost:5303/"},
	{"name":"octane-tsrx-terser","url":"http://localhost:6402/"},
	{"name":"react-terser","url":"http://localhost:6403/"},
	{"name":"octane-tsrx-old","url":"http://localhost:6302/"},
	{"name":"react-old","url":"http://localhost:6303/"}
]' BENCH_JSON="$OUT/svg-dashboard-ab.json" node benchmarks/svg-dashboard/run.mjs "$ITER" || echo "svg-dashboard A/B exited $?"
