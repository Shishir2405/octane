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
	"p833 6927595656860f12fef79948135f5f1ee29595c2"
	"at833 5f7a4579bab1a9987cb54fb6b2fc1f314497fc3c"
	"main ac729dc14832c082b77cd1bf03b8fb7509ced89a"
	"cand a0746246a9946bc9717d1d6d77b392b01a865ebd"
	"nojrn 864227f7036dab69f94d110d727664acdd1870f3"
)

pnpm --filter react-compiler-memowall-bench build >"$OUT/build-react-mw.log" 2>&1
serve benchmarks/memo-wall/react-compiler 5226

MW_T='{"name":"react","url":"http://localhost:5226/"}'

i=0
for entry in "${COMMITS[@]}"; do
	read -r name sha <<<"$entry"
	tree "$sha" $MW
	serve "/tmp/at-$sha/benchmarks/memo-wall/octane-tsrx" $((7100 + i))
	MW_T="$MW_T,{\"name\":\"$name\",\"url\":\"http://localhost:$((7100 + i))/\"}"
	i=$((i + 1))
done

TARGETS="[$MW_T]" BENCH_JSON="$OUT/memo-wall-attrib.json" node benchmarks/memo-wall/run.mjs "$ITER" || echo "memo-wall exited $?"
