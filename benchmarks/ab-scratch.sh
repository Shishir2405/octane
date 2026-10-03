#!/usr/bin/env bash
# Scratch A/B (never merged): svg-dashboard's Octane fixture built at main and at
# the read-once candidate, served at once beside React and driven by this
# head's paired harness on one runner. Each commit builds with its own deps.
set -euo pipefail
ROOT=$PWD
OUT=$ROOT/benchmarks/results
mkdir -p "$OUT"
ITER=${AB_ITER:-20}

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

SVG=octane-tsrx-svg-dashboard-bench

# name sha: main and the read-once candidate (perf/scoped-value-repeat-reads).
COMMITS=(
	"main 950ef0b0bd80b87e8a2777b068dec65c6905eabb"
	"cand 6e541598d4c016518731f3e18232081c8c43c3cf"
)

pnpm --filter react-svg-dashboard-bench build >"$OUT/build-react-svg.log" 2>&1
serve benchmarks/svg-dashboard/react 5303
SVG_T='{"name":"react","url":"http://localhost:5303/"}'

i=0
for entry in "${COMMITS[@]}"; do
	read -r name sha <<<"$entry"
	tree "$sha" $SVG
	serve "/tmp/at-$sha/benchmarks/svg-dashboard/octane-tsrx" $((7200 + i))
	SVG_T="$SVG_T,{\"name\":\"$name\",\"url\":\"http://localhost:$((7200 + i))/\"}"
	i=$((i + 1))
done

# Two independent paired passes; each rotates target order every round.
for pass in 1 2; do
	TARGETS="[$SVG_T]" BENCH_JSON="$OUT/svg-dashboard-ab-$pass.json" node benchmarks/svg-dashboard/run.mjs "$ITER" || echo "svg-dashboard pass $pass exited $?"
done
