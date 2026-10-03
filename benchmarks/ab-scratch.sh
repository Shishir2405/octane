#!/usr/bin/env bash
# Scratch attribution (never merged): the Octane fixtures of js-framework-reorder,
# memo-wall and svg-dashboard built at several commits, all served at once and
# driven by this head's paired harness. Each commit builds with its own deps.
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
serve() {
	local dir=$1 port=$2; shift 2
	(cd "$dir" && setsid nohup pnpm exec vite preview --port "$port" --strictPort "$@" >"$OUT/serve-$port.log" 2>&1 &)
	wait_port "$port"
}
# tree <sha> <fixture package...>: a detached checkout at /tmp/at-<sha> with
# its own install and the named fixtures built.
tree() {
	local sha=$1; shift
	git fetch --no-tags --depth=1 origin "$sha"
	git worktree add --detach "/tmp/at-$sha" "$sha"
	local args=()
	for f in "$@"; do args+=(--filter "$f..."); done
	(cd "/tmp/at-$sha" && pnpm install --frozen-lockfile --prefer-offline --ignore-scripts --filter octane-monorepo "${args[@]}") >"$OUT/install-$sha.log" 2>&1 || { tail -50 "$OUT/install-$sha.log"; return 1; }
	for f in "$@"; do (cd "/tmp/at-$sha" && pnpm --filter "$f" build) >"$OUT/build-$sha-$f.log" 2>&1 || { tail -50 "$OUT/build-$sha-$f.log"; return 1; }; done
}

JS=octane-tsrx-jsbench
MW=octane-tsrx-memowall-bench
SVG=octane-tsrx-svg-dashboard-bench

# name sha
COMMITS=(
	"o639 73b22fd1185db202f218e1a7e9e230571ef01c30"
	"p833 6927595656860f12fef79948135f5f1ee29595c2"
	"c833 5f7a4579bab1a9987cb54fb6b2fc1f314497fc3c"
	"p1057 43568efdbdb058f825b8e174c9a4fdebefcacdc5"
	"c1057 2789eab27ced3e2519cba4508b8e6aa9e728a3eb"
	"p1069 1ed5d2ab9c6291b734a70a102c78b25c8bcdb3d1"
	"c1069 5ead1ff2c000f3bb322e7d4fd1d5786161195189"
	"main 421287457cf834629f67436fc313ec8cc82f1d7b"
)
SVG_OLD=7a6fba3aef8a0bb1c9f5a01ca00bbcec0e4aa6f1

pnpm --filter react-jsbench build >"$OUT/build-react-js.log" 2>&1
pnpm --filter react-compiler-memowall-bench build >"$OUT/build-react-mw.log" 2>&1
pnpm --filter react-svg-dashboard-bench build >"$OUT/build-react-svg.log" 2>&1
serve benchmarks/js-framework/react 5175
serve benchmarks/memo-wall/react-compiler 5226
serve benchmarks/svg-dashboard/react 5303

JS_T='{"name":"react","url":"http://localhost:5175/","ready":"#run"}'
MW_T='{"name":"react","url":"http://localhost:5226/"}'
SVG_T='{"name":"react","url":"http://localhost:5303/"}'

i=0
for entry in "${COMMITS[@]}"; do
	read -r name sha <<<"$entry"
	if [ "$name" = o639 ]; then
		tree "$sha" $JS $MW
	else
		tree "$sha" $JS $MW $SVG
	fi
	serve "/tmp/at-$sha/benchmarks/js-framework/octane-tsrx" $((7000 + i))
	JS_T="$JS_T,{\"name\":\"$name\",\"url\":\"http://localhost:$((7000 + i))/\",\"ready\":\"#run\"}"
	serve "/tmp/at-$sha/benchmarks/memo-wall/octane-tsrx" $((7100 + i))
	MW_T="$MW_T,{\"name\":\"$name\",\"url\":\"http://localhost:$((7100 + i))/\"}"
	if [ "$name" != o639 ]; then
		serve "/tmp/at-$sha/benchmarks/svg-dashboard/octane-tsrx" $((7200 + i))
		SVG_T="$SVG_T,{\"name\":\"$name\",\"url\":\"http://localhost:$((7200 + i))/\"}"
	fi
	i=$((i + 1))
done
tree $SVG_OLD $SVG
serve "/tmp/at-$SVG_OLD/benchmarks/svg-dashboard/octane-tsrx" 7299
SVG_T="$SVG_T,{\"name\":\"o635\",\"url\":\"http://localhost:7299/\"}"

TARGETS="[$JS_T]" BENCH_JSON="$OUT/js-framework-reorder-attrib.json" node benchmarks/js-framework/run-reorder.mjs "$ITER" || echo "reorder exited $?"
TARGETS="[$MW_T]" BENCH_JSON="$OUT/memo-wall-attrib.json" node benchmarks/memo-wall/run.mjs "$ITER" || echo "memo-wall exited $?"
TARGETS="[$SVG_T]" BENCH_JSON="$OUT/svg-dashboard-attrib.json" node benchmarks/svg-dashboard/run.mjs "$ITER" || echo "svg-dashboard exited $?"
