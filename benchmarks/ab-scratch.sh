#!/usr/bin/env bash
# Scratch A/B (never merged): the warm-plan checkpoint guard (this head's parent
# commit) against main without it. memo-wall and recursive-context octane-tsrx
# fixtures are built in both trees and each build is served twice, so one paired
# run (ab-guard.mjs) measures the A/B and the same-build spread together.
# js-framework runs through pair.mjs: once head vs base, once head vs itself.
set -euo pipefail
ROOT=$PWD
OUT=$ROOT/benchmarks/results
mkdir -p "$OUT"
BASE_SHA=ac729dc14832c082b77cd1bf03b8fb7509ced89a
BASE=/tmp/ab-base
RUNS=${AB_RUNS:-3}

wait_port() {
	for _ in $(seq 1 240); do
		curl -sf "http://localhost:$1/" >/dev/null && return 0
		sleep 0.5
	done
	echo "port $1 never came up"; cat "$OUT/serve-$1.log" || true; return 1
}
serve() {
	local dir=$1 port=$2
	(cd "$dir" && setsid nohup pnpm exec vite preview --port "$port" --strictPort >"$OUT/serve-$port.log" 2>&1 &)
	wait_port "$port"
}

git fetch --no-tags --depth=1 origin "$BASE_SHA"
git worktree add --detach "$BASE" "$BASE_SHA"
echo "== source diff, base → head (packages/ only):"
git diff --stat "$BASE_SHA" HEAD -- packages/ | tee "$OUT/source-diff.txt"
git diff "$BASE_SHA" HEAD -- packages/ >>"$OUT/source-diff.txt"
(cd "$BASE" && pnpm install --prod false --frozen-lockfile) >"$OUT/install-base.log" 2>&1 || { tail -50 "$OUT/install-base.log"; exit 1; }

for f in octane-tsrx-memowall-bench octane-tsrx-recursive-bench; do
	pnpm --filter "$f" build >"$OUT/build-head-$f.log" 2>&1 || { tail -50 "$OUT/build-head-$f.log"; exit 1; }
	(cd "$BASE" && pnpm --filter "$f" build) >"$OUT/build-base-$f.log" 2>&1 || { tail -50 "$OUT/build-base-$f.log"; exit 1; }
done
echo "== built assets (head, then base):"
for d in benchmarks/memo-wall/octane-tsrx benchmarks/recursive-context/octane-tsrx; do
	ls -l "$d/dist/assets" "$BASE/$d/dist/assets" | tee -a "$OUT/assets.txt"
	md5sum "$d"/dist/assets/*.js "$BASE/$d"/dist/assets/*.js | tee -a "$OUT/assets.txt"
done

serve benchmarks/memo-wall/octane-tsrx 5206
serve "$BASE/benchmarks/memo-wall/octane-tsrx" 6206
serve benchmarks/memo-wall/octane-tsrx 5216
serve "$BASE/benchmarks/memo-wall/octane-tsrx" 6216
serve benchmarks/recursive-context/octane-tsrx 5185
serve "$BASE/benchmarks/recursive-context/octane-tsrx" 6185
serve benchmarks/recursive-context/octane-tsrx 5195
serve "$BASE/benchmarks/recursive-context/octane-tsrx" 6195

status=0
for run in $(seq 1 "$RUNS"); do
	AB_RUN=$run AB_PAIRS=${AB_PAIRS:-60} node benchmarks/ab-guard.mjs || { echo "ab-guard run $run exited $?"; status=1; }
done

echo "== js-framework pair.mjs head vs base"
node benchmarks/js-framework/pair.mjs --base-tree="$BASE" --pairs=${AB_JS_PAIRS:-40} \
	--base-json="$OUT/js-ab-base.json" --head-json="$OUT/js-ab-head.json" 2>&1 | tee "$OUT/js-ab.log" || status=1
echo "== js-framework pair.mjs head vs head (A/A)"
node benchmarks/js-framework/pair.mjs --base-tree="$ROOT" --no-build --pairs=${AB_JS_PAIRS:-40} \
	--base-json="$OUT/js-aa-base.json" --head-json="$OUT/js-aa-head.json" 2>&1 | tee "$OUT/js-aa.log" || status=1
{
	echo '### js-framework head/base (pair.mjs)'
	echo '```'
	grep -E 'head/base|Pairing' "$OUT/js-ab.log" || true
	echo '```'
	echo '### js-framework A/A head/head (pair.mjs)'
	echo '```'
	grep -E 'head/base|Pairing' "$OUT/js-aa.log" || true
	echo '```'
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
exit $status
