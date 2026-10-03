// Count root-transaction setup allocations reached per ordinary commit in a
// production runtime. The observed runtime wraps every object, array, `new`,
// and closure expression in the functions that open, enter, leave, commit, and
// recycle a root transaction. Clean and observed bundles must produce the same
// public DOM, effect, ref, event, and cleanup results.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { gzipSync } from 'node:zlib';
import { build } from 'esbuild';
import { Window } from 'happy-dom';
import ts from 'typescript';
import { compile } from '../../packages/octane/src/compiler/compile.js';

process.env.NODE_ENV = 'production';
const repo = path.resolve(import.meta.dirname, '../..');
const runtimeFile = path.resolve(
	process.argv[2] ?? path.join(repo, 'packages/octane/src/runtime.ts'),
);
const runtimeSource = fs.readFileSync(runtimeFile, 'utf8');
const runtimePath = path.join(repo, 'packages/octane/src/runtime.ts');
const SETUP_FUNCTIONS = [
	'beginRootRender',
	'endRootRender',
	'createOffscreenCapture',
	'commitRootRenders',
	'recycleRootTransaction',
	'emptyReusedArray',
];
const ast = ts.createSourceFile(runtimePath, runtimeSource, ts.ScriptTarget.Latest, true);
const insertions = [];
const instrumented = [];
for (const statement of ast.statements) {
	if (!ts.isFunctionDeclaration(statement) || !SETUP_FUNCTIONS.includes(statement.name?.text))
		continue;
	instrumented.push(statement.name.text);
	const visit = (node) => {
		if (
			ts.isObjectLiteralExpression(node) ||
			ts.isArrayLiteralExpression(node) ||
			ts.isNewExpression(node) ||
			ts.isArrowFunction(node) ||
			ts.isFunctionExpression(node)
		) {
			insertions.push([node.getStart(ast), '(globalThis.__rootSetupAllocations++, ']);
			insertions.push([node.end, ')']);
		}
		ts.forEachChild(node, visit);
	};
	visit(statement.body);
}
for (const name of ['beginRootRender', 'createOffscreenCapture', 'commitRootRenders'])
	assert.ok(instrumented.includes(name), `${name} is instrumented`);
let observedRuntime = runtimeSource;
for (const [position, text] of insertions.sort((a, b) => b[0] - a[0]))
	observedRuntime = observedRuntime.slice(0, position) + text + observedRuntime.slice(position);

const source = `import { use, useEffect, useLayoutEffect, useState } from 'octane';
let setCount;
export function tick(value) { setCount(value); }
function Row(props) @{ <li data-row={props.id}>{String(props.id)}</li> }
function Rows(props) @{ <ul>@for (const id of props.rows; key id) { <Row id={id} /> }</ul> }
function Reader(props) @{ const value = use(props.promise); <output>{value as string}</output> }
function Effects(props) @{
  useLayoutEffect(() => { props.observe('layout:' + props.label); return () => props.observe('unlayout'); }, [props.label]);
  useEffect(() => { props.observe('passive:' + props.label); return () => props.observe('unpassive'); }, [props.label]);
  <i ref={props.even ? props.refA : props.refB}>{props.label as string}</i>
}
export function App(props) @{
  const [count, set] = useState(0);
  setCount = set;
  const label = props.label + ':' + count;
  <section>
    <h2><span>{label as string}</span></h2>
    <button onClick={() => props.record(label)}>{label as string}</button>
    @if (props.effects) {
      <Effects label={label} even={count % 2 === 0} observe={props.observe} refA={props.refA} refB={props.refB} />
    }
    <Rows rows={props.rows} />
    <Reader promise={props.promise} />
  </section>
}`;
const code = compile(source, 'root-transaction-setup.tsrx', { dev: false, hmr: false }).code;
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'octane-root-transaction-setup-'));
const window = new Window();
for (const name of [
	'window',
	'document',
	'Node',
	'Element',
	'HTMLElement',
	'SVGElement',
	'Text',
	'Comment',
	'Event',
	'MouseEvent',
	'MutationObserver',
]) {
	globalThis[name] = name === 'window' ? window : window[name];
}
const WARMUP = 16;
const COMMITS = 64;
const rows = Array.from({ length: 16 }, (_, id) => id);
const fulfilled = (value) => ({ status: 'fulfilled', value, then() {} });
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const liveRefs = (refs) =>
	refs.reduce((live, entry) => live + (entry.endsWith(':null') ? -1 : 1), 0);
const results = [];
let size;
try {
	for (const observed of [false, true]) {
		const outfile = path.join(scratch, `${observed}.mjs`);
		const bundle = await build({
			stdin: {
				contents: code + '\nexport {createRoot, flushSync} from "octane";',
				resolveDir: repo,
				loader: 'js',
			},
			outfile,
			bundle: true,
			format: 'esm',
			platform: 'node',
			minify: true,
			write: false,
			define: { 'process.env.NODE_ENV': '"production"', __OCTANE_PROFILE_ENABLED__: 'false' },
			plugins: [
				{
					name: 'selected-runtime',
					setup(plugin) {
						plugin.onResolve(
							{ filter: /^octane(?:\/internal\/client)?$/ },
							({ path: request }) => ({
								path: path.join(
									repo,
									'packages/octane/src',
									request === 'octane' ? 'index.ts' : 'internal/client.ts',
								),
							}),
						);
						plugin.onLoad({ filter: /\/runtime\.ts$/ }, ({ path: loaded }) =>
							loaded === runtimePath
								? {
										contents: observed ? observedRuntime : runtimeSource,
										loader: 'ts',
										resolveDir: path.dirname(runtimePath),
									}
								: null,
						);
					},
				},
			],
		});
		fs.writeFileSync(outfile, bundle.outputFiles[0].text);
		if (!observed)
			size = {
				minified: bundle.outputFiles[0].contents.length,
				gzip: gzipSync(bundle.outputFiles[0].contents).length,
			};
		const { App, createRoot, flushSync, tick } = await import(pathToFileURL(outfile));
		const result = {};
		// tick: a state update re-renders one component (the memo-wall shape).
		// props: a public root.render request. effects: each commit re-runs a
		// layout and a passive effect and swaps a callback ref, so the captured
		// queues are not empty. after-hold: the same commits once a root-level
		// suspension (no boundary) has held and retried.
		for (const mode of ['tick', 'props', 'effects', 'after-hold']) {
			const container = document.createElement('main');
			document.body.append(container);
			const root = createRoot(container);
			const observations = [];
			const refs = [];
			const recorded = [];
			const props = {
				label: mode,
				rows,
				promise: fulfilled('ready'),
				effects: mode === 'effects' || mode === 'after-hold',
				observe: (entry) => observations.push(entry),
				refA: (el) => refs.push(el === null ? 'a:null' : 'a'),
				refB: (el) => refs.push(el === null ? 'b:null' : 'b'),
				record: (label) => recorded.push(label),
			};
			root.render(App, props);
			flushSync(() => {});
			const items = Array.from(container.querySelectorAll('li'));
			let count = 0;
			let label = mode;
			const commit = () => {
				count++;
				if (mode === 'props') {
					label = mode + count;
					flushSync(() => root.render(App, { ...props, label }));
				} else flushSync(() => tick(count));
			};
			for (let i = 0; i < WARMUP; i++) commit();
			if (mode === 'after-hold') {
				let resolve;
				const promise = new Promise((accept) => (resolve = accept));
				flushSync(() => root.render(App, { ...props, label: 'held', promise }));
				assert.equal(container.querySelector('span').textContent, `${label}:${count}`);
				resolve('resolved');
				await settle();
				flushSync(() => {});
				label = 'held';
				assert.equal(container.querySelector('span').textContent, `held:${count}`);
				assert.equal(container.querySelector('output').textContent, 'resolved');
				for (let i = 0; i < WARMUP; i++) commit();
			}
			globalThis.__rootSetupAllocations = 0;
			for (let i = 0; i < COMMITS; i++) commit();
			const allocations = globalThis.__rootSetupAllocations;
			const expected = mode === 'props' ? `${label}:0` : `${label}:${count}`;
			assert.equal(container.querySelector('span').textContent, expected);
			assert.equal(container.querySelector('button').textContent, expected);
			assert.deepEqual(Array.from(container.querySelectorAll('li')), items, 'row identity');
			container
				.querySelector('button')
				.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
			assert.deepEqual(recorded, [expected], 'accepted handler environment');
			await settle();
			flushSync(() => {});
			const layouts = observations.filter((entry) => entry.startsWith('layout:'));
			const passives = observations.filter((entry) => entry.startsWith('passive:'));
			if (props.effects) {
				assert.equal(layouts.at(-1), 'layout:' + expected);
				assert.equal(passives.at(-1), 'passive:' + expected);
				assert.equal(
					observations.filter((entry) => entry === 'unlayout').length,
					layouts.length - 1,
				);
				assert.equal(
					observations.filter((entry) => entry === 'unpassive').length,
					passives.length - 1,
				);
				assert.equal(liveRefs(refs), 1);
				assert.ok(refs.length > 2 * COMMITS, 'each commit swaps the callback ref');
			} else assert.deepEqual(observations, []);
			root.unmount();
			assert.equal(container.childNodes.length, 0);
			if (props.effects) {
				assert.equal(observations.filter((entry) => entry === 'unlayout').length, layouts.length);
				assert.equal(observations.filter((entry) => entry === 'unpassive').length, passives.length);
				assert.equal(liveRefs(refs), 0);
			}
			container.remove();
			result[mode] = {
				allocations,
				commits: COMMITS,
				semantic: [expected, layouts.length, passives.length, refs.length].join(','),
			};
		}
		results.push(result);
	}
	for (const mode of Object.keys(results[0]))
		assert.equal(results[0][mode].semantic, results[1][mode].semantic, `${mode} semantic`);
	const value = (median) => ({ median, min: median, samples: 1 });
	const report = {
		suite: 'root-transactions',
		runtimeFile,
		runtimeSha256: createHash('sha256').update(runtimeSource).digest('hex'),
		sourceSha256: createHash('sha256').update(source).digest('hex'),
		node: process.version,
		instrumented,
		allocationSites: insertions.length / 2,
		size,
		results: results[1],
		targets: Object.entries(results[1]).flatMap(([mode, result]) => [
			{
				name: `setup-${mode}`,
				ops: { setup_allocations: value(result.allocations), commits: value(result.commits) },
				meta: { gate: 'passed', semantic: result.semantic },
			},
			{
				name: `setup-${mode}-work`,
				ops: { setup_allocations: value(result.commits) },
				meta: { gate: 'passed' },
			},
		]),
		limitations: [
			'Reached allocation expressions in the root-transaction setup functions count source work, not heap bytes, array growth, or timing.',
			'Happy DOM checks public output, effects, refs, events, and cleanup; this is not a browser timing measurement.',
		],
	};
	if (process.env.BENCH_JSON)
		fs.writeFileSync(process.env.BENCH_JSON, JSON.stringify(report, null, 2) + '\n');
	console.log(JSON.stringify(report, null, 2));
} finally {
	await window.happyDOM.close();
	fs.rmSync(scratch, { recursive: true, force: true });
}
// Passive effects install the runtime's post-paint MessageChannel, whose open
// port would otherwise keep this process alive after a successful report.
process.exit(0);
