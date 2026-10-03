#!/usr/bin/env bash
# Scratch attribution (never merged): the Octane fixtures of js-framework-reorder,
# memo-wall and svg-dashboard built at several commits, all served at once and
# driven by this head's paired harness. Each commit builds with its own deps.
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
	"main 950ef0b0bd80b87e8a2777b068dec65c6905eabb"
	"m3 444f63f35074e72222f650670d26588067464d6f"
	"m4 0f86fc137c2271d132c0f57d9a68c88608e139cc"
)

pnpm --filter react-jsbench build >"$OUT/build-react-js.log" 2>&1
pnpm --filter react-compiler-memowall-bench build >"$OUT/build-react-mw.log" 2>&1
serve benchmarks/js-framework/react 5175
serve benchmarks/memo-wall/react-compiler 5226

JS_T='{"name":"react","url":"http://localhost:5175/","ready":"#run"}'
MW_T='{"name":"react","url":"http://localhost:5226/"}'

i=0
for entry in "${COMMITS[@]}"; do
	read -r name sha <<<"$entry"
	tree "$sha" $JS $MW
	serve "/tmp/at-$sha/benchmarks/js-framework/octane-tsrx" $((7000 + i))
	JS_T="$JS_T,{\"name\":\"$name\",\"url\":\"http://localhost:$((7000 + i))/\",\"ready\":\"#run\"}"
	serve "/tmp/at-$sha/benchmarks/memo-wall/octane-tsrx" $((7100 + i))
	MW_T="$MW_T,{\"name\":\"$name\",\"url\":\"http://localhost:$((7100 + i))/\"}"
	i=$((i + 1))
done

TARGETS="[$MW_T]" BENCH_JSON="$OUT/memo-wall-attrib.json" node benchmarks/memo-wall/run.mjs "$ITER" || echo "memo-wall exited $?"
TARGETS="[$JS_T]" BENCH_JSON="$OUT/js-framework-reorder-attrib.json" node benchmarks/js-framework/run-reorder.mjs "$ITER" || echo "reorder exited $?"
