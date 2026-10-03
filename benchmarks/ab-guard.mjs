// Scratch A/B driver (never merged): the warm-plan checkpoint guard.
//
// Every target page of a suite is open at once, each in its own context. Each
// sample round visits every target in a rotating order and times one ~20 ms
// batch of the operation, so runner drift lands on all sides of a round
// together. All targets run the identical operation sequence: one rep count is
// calibrated on the base page and its calibration trials are replayed on the
// others. Their final DOM and render probes must therefore match exactly, which
// is the semantic control.
//
// Targets: base and head, plus a second server for each build. head/base and
// head-again/base-again are two A/B estimates; base-again/base and
// head-again/head are the same-build (A/A) spread under the same procedure.

import { chromium } from 'playwright';
import fs from 'node:fs';
import { roundOrder, SAMPLE_MS } from './lib/paired.mjs';
import { pairedRatio } from './lib/stats.mjs';

const PAIRS = Number(process.env.AB_PAIRS ?? 60);
const WARMUP = 6;
const MAX_REPS = 65_536;
const RUN = process.env.AB_RUN ?? '1';
const OUT = process.env.AB_OUT ?? 'benchmarks/results';
const SIDES = ['base', 'head', 'base-again', 'head-again'];
const COMPARISONS = [
	['head', 'base', 'A/B'],
	['head-again', 'base-again', 'A/B'],
	['base-again', 'base', 'A/A'],
	['head-again', 'head', 'A/A'],
];

const SUITES = [
	{
		suite: 'memo-wall',
		ports: { base: 6206, head: 5206, 'base-again': 6216, 'head-again': 5216 },
		ops: [
			{ name: 'parent_rerender_equal_A', hook: '__tickA', reps: 10 },
			{ name: 'parent_rerender_equal_B', hook: '__tickB', reps: 10 },
			{ name: 'one_change_A', hook: '__oneChangeA', reps: 10 },
			{ name: 'one_change_B', hook: '__oneChangeB', reps: 10 },
			{ name: 'ctx_through_wall_A', hook: '__ctxA', reps: 4 },
			{ name: 'ctx_through_wall_B', hook: '__ctxB', reps: 4 },
			{ name: 'remount', hook: '__abRemount', reps: 1 },
		],
	},
	{
		suite: 'recursive-context',
		ports: { base: 6185, head: 5185, 'base-again': 6195, 'head-again': 5195 },
		ops: [
			{ name: 'update_root', hook: '__updateRoot', reps: 4 },
			{ name: 'update_partial', hook: '__updatePartial', reps: 10 },
			{ name: 'partial_cycle', hook: '__abPartialCycle', reps: 2 },
			{ name: 'remount', hook: '__abRemount', reps: 1 },
		],
	},
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const median = (values) => {
	const sorted = [...values].sort((a, b) => a - b);
	const middle = sorted.length >> 1;
	return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};

async function openTarget(browser, side, port, hook) {
	const ctx = await browser.newContext();
	const page = await ctx.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(`http://localhost:${port}/`, { waitUntil: 'load' });
	await page.waitForFunction(() => window.__ready === true, null, { timeout: 10_000 });
	await page.evaluate((hook) => {
		window.__abRemount = () => {
			(window.__reset ?? window.__unmount)();
			window.__mount();
		};
		window.__abPartialCycle = () => {
			window.__partialUnmount();
			window.__partialRemount();
		};
		window.__mount();
		const fn = window[hook];
		if (typeof fn !== 'function') throw new Error('missing ' + hook);
		window.__abBatch = (count) => {
			void document.body?.offsetHeight;
			const t0 = performance.now();
			for (let k = 0; k < count; k++) fn();
			return performance.now() - t0;
		};
	}, hook);
	return { side, ctx, page, errors, samples: [] };
}

function snapshot() {
	const clone = document.body.cloneNode(true);
	for (const script of clone.querySelectorAll('script')) script.remove();
	const html = clone.innerHTML;
	let hash = 0x811c9dc5;
	for (let i = 0; i < html.length; i++) {
		hash ^= html.charCodeAt(i);
		hash = Math.imul(hash, 0x01000193);
	}
	return {
		hash: hash >>> 0,
		length: html.length,
		renders: window.__renders ? JSON.stringify(window.__renders) : null,
	};
}

async function measure(browser, suite, op) {
	const targets = [];
	try {
		for (const side of SIDES) {
			targets.push(await openTarget(browser, side, suite.ports[side], op.hook));
		}
		await sleep(50);
		// Warm, then calibrate on base and replay the identical trials elsewhere.
		const [base] = targets;
		await base.page.bringToFront();
		const { reps, trials } = await base.page.evaluate(
			({ initialReps, SAMPLE_MS, MAX_REPS }) => {
				const gc = window.gc || (() => {});
				const trials = [initialReps];
				window.__abBatch(initialReps);
				let reps = initialReps;
				for (;;) {
					gc();
					const elapsed = window.__abBatch(reps);
					trials.push(reps);
					if (elapsed >= SAMPLE_MS || reps >= MAX_REPS) break;
					const estimated = elapsed > 0 ? Math.ceil((reps * SAMPLE_MS) / elapsed) : reps * 10;
					reps = Math.min(MAX_REPS, Math.max(reps * 2, estimated));
				}
				return { reps, trials };
			},
			{ initialReps: op.reps, SAMPLE_MS, MAX_REPS },
		);
		const replay = trials.reduce((sum, count) => sum + count, 0);
		for (const target of targets.slice(1)) {
			await target.page.bringToFront();
			await target.page.evaluate((count) => window.__abBatch(count), replay);
		}
		for (let i = 0; i < WARMUP + PAIRS; i++) {
			for (const target of roundOrder(targets, i)) {
				await target.page.bringToFront();
				const dt = await target.page.evaluate((reps) => {
					(window.gc || (() => {}))();
					return window.__abBatch(reps) / reps;
				}, reps);
				if (i >= WARMUP) target.samples.push(dt);
				await sleep(5);
			}
		}
		const snapshots = [];
		for (const target of targets) snapshots.push(await target.page.evaluate(snapshot));
		const gate = [];
		for (let i = 1; i < targets.length; i++) {
			if (JSON.stringify(snapshots[i]) !== JSON.stringify(snapshots[0])) {
				gate.push(`${targets[i].side} ${JSON.stringify(snapshots[i])} != base ${JSON.stringify(snapshots[0])}`);
			}
		}
		for (const target of targets) {
			if (target.errors.length > 0) gate.push(`${target.side} page errors: ${target.errors.join('; ')}`);
		}
		const samples = Object.fromEntries(targets.map((t) => [t.side, t.samples]));
		return { reps, samples, gate, snapshot: snapshots[0] };
	} finally {
		for (const target of targets) await target.ctx.close();
	}
}

const browser = await chromium.launch({
	headless: true,
	args: ['--disable-extensions', '--no-sandbox', '--js-flags=--expose-gc'],
});
const results = [];
const lines = [
	`### Run ${RUN}: ${PAIRS} rounds per op (+${WARMUP} warmup), ratio = median paired ratio [95% bootstrap]`,
	'',
	'| suite | op | reps | base ms | head ms | head/base | head2/base2 | A/A base2/base | A/A head2/head | gate |',
	'|---|---|---|---|---|---|---|---|---|---|',
];
const fmt = ({ ratio, low, high }) => `${ratio.toFixed(3)} [${low.toFixed(3)}, ${high.toFixed(3)}]`;
let failed = false;
try {
	for (const suite of SUITES) {
		for (const op of suite.ops) {
			console.error(`${suite.suite} ${op.name}…`);
			const result = await measure(browser, suite, op);
			const ratios = Object.fromEntries(
				COMPARISONS.map(([after, before]) => [
					`${after}/${before}`,
					pairedRatio(result.samples[before], result.samples[after]),
				]),
			);
			results.push({ suite: suite.suite, op: op.name, ...result, ratios });
			if (result.gate.length > 0) failed = true;
			lines.push(
				`| ${suite.suite} | ${op.name} | ${result.reps} | ${median(result.samples.base).toFixed(4)} | ${median(result.samples.head).toFixed(4)} | ${COMPARISONS.map(([after, before]) => fmt(ratios[`${after}/${before}`])).join(' | ')} | ${result.gate.length === 0 ? 'pass' : 'FAIL'} |`,
			);
			for (const message of result.gate) console.error(`  ✗ ${message}`);
		}
	}
} finally {
	await browser.close();
}
lines.push('');
const report = lines.join('\n');
console.log(report);
if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, report + '\n');
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(`${OUT}/ab-guard-run${RUN}.json`, JSON.stringify(results, null, '\t') + '\n');
if (failed) process.exitCode = 1;
