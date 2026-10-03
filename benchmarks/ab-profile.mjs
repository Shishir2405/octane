// Scratch attribution (never merged): per-op precise call counts and a sampled
// CPU profile of memo-wall's __tickA for several unminified builds.
import { chromium } from 'playwright';
import fs from 'node:fs';

const TARGETS = JSON.parse(process.env.TARGETS);
const OPS = Number(process.env.PROFILE_OPS || 200000);
const out = {};
const browser = await chromium.launch({ args: ['--js-flags=--expose-gc'] });
try {
	for (let round = 0; round < 2; round++) {
		for (const target of TARGETS) {
			const context = await browser.newContext();
			const page = await context.newPage();
			await page.goto(target.url, { waitUntil: 'load' });
			await page.waitForFunction(() => window.__ready === true);
			await page.evaluate(() => window.__mount());
			await page.evaluate(() => {
				for (let i = 0; i < 20000; i++) window.__tickA();
			});
			const cdp = await context.newCDPSession(page);
			await cdp.send('Profiler.enable');
			const entry = (out[target.name] ??= { calls: null, profiles: [] });
			if (round === 0) {
				await cdp.send('Profiler.startPreciseCoverage', { callCount: true, detailed: false });
				await cdp.send('Profiler.takePreciseCoverage');
				await page.evaluate(() => {
					for (let i = 0; i < 100; i++) window.__tickA();
				});
				const coverage = await cdp.send('Profiler.takePreciseCoverage');
				await cdp.send('Profiler.stopPreciseCoverage');
				const calls = {};
				let total = 0;
				for (const script of coverage.result) {
					if (!script.url.includes('/assets/')) continue;
					for (const fn of script.functions) {
						const count = (fn.ranges[0]?.count ?? 0) / 100;
						if (count === 0 || !fn.functionName) continue;
						calls[fn.functionName] = (calls[fn.functionName] ?? 0) + count;
						total += count;
					}
				}
				entry.calls = { total, byFunction: calls };
			}
			await cdp.send('Profiler.setSamplingInterval', { interval: 25 });
			await cdp.send('Profiler.start');
			const wall = await page.evaluate((ops) => {
				const t0 = performance.now();
				for (let i = 0; i < ops; i++) window.__tickA();
				return performance.now() - t0;
			}, OPS);
			const { profile } = await cdp.send('Profiler.stop');
			const self = new Map();
			const byId = new Map(profile.nodes.map((node) => [node.id, node]));
			const counts = new Map();
			for (const id of profile.samples) counts.set(id, (counts.get(id) ?? 0) + 1);
			let samples = 0;
			for (const [id, count] of counts) {
				const node = byId.get(id);
				const frame = node.callFrame;
				const key = frame.functionName || `(${frame.url ? 'anonymous' : frame.functionName || 'native'})`;
				self.set(key, (self.get(key) ?? 0) + count);
				samples += count;
			}
			entry.profiles.push({
				wallMs: wall,
				usPerOp: (wall * 1000) / OPS,
				samples,
				self: Object.fromEntries(
					[...self.entries()]
						.sort((a, b) => b[1] - a[1])
						.slice(0, 80)
						.map(([name, count]) => [name, Number(((count / samples) * 100).toFixed(2))]),
				),
			});
			await context.close();
		}
	}
} finally {
	await browser.close();
}
fs.writeFileSync(process.env.BENCH_JSON, JSON.stringify(out, null, 2));
console.log(JSON.stringify(Object.fromEntries(Object.entries(out).map(([k, v]) => [k, { calls: v.calls.total, us: v.profiles.map((p) => p.usPerOp.toFixed(3)) }]))));
