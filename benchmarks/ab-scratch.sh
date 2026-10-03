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

SPA_OLD=3d093488363eebc1f093ebcc3025f76827073fad

# spa-navigation: octane-tsrx vs solid. The alt build is unminified, as both
# fixtures were before #983.
old_tree $SPA_OLD octane-tsrx-spa-navigation-bench solid-spa-navigation-bench
build_new octane-tsrx-spa-navigation-bench
build_new solid-spa-navigation-bench
serve benchmarks/spa-navigation/octane-tsrx 5310
serve benchmarks/spa-navigation/solid 5313
serve benchmarks/spa-navigation/octane-tsrx 6410 --config vite.alt.config.js
serve benchmarks/spa-navigation/solid 6413 --config vite.alt.config.js
serve /tmp/old-$SPA_OLD/benchmarks/spa-navigation/octane-tsrx 6310
serve /tmp/old-$SPA_OLD/benchmarks/spa-navigation/solid 6313
TARGETS='[
	{"name":"octane-tsrx","url":"http://localhost:5310/"},
	{"name":"solid","url":"http://localhost:5313/"},
	{"name":"octane-tsrx-unminified","url":"http://localhost:6410/"},
	{"name":"solid-unminified","url":"http://localhost:6413/"},
	{"name":"octane-tsrx-old","url":"http://localhost:6310/"},
	{"name":"solid-old","url":"http://localhost:6313/"}
]' BENCH_JSON="$OUT/spa-navigation-ab.json" node benchmarks/spa-navigation/run.mjs "$ITER" || echo "spa-navigation A/B exited $?"
