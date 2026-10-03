import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { beforeAll, describe, expect, it } from 'vitest';
import { createRoot, flushSync, hydrateRoot } from 'octane';
import { renderToString } from 'octane/server';
import { act } from './_helpers';
import * as plain from './_fixtures/root-transaction-reuse.tsrx';

interface Fixture {
	ReuseApp: any;
	Mirror: any;
	updateTick(value: number): void;
}

const SOURCE = readFileSync(
	join(process.cwd(), 'packages/octane/tests/_fixtures/root-transaction-reuse.tsrx'),
	'utf8',
);

function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((accept) => {
		resolve = accept;
	});
	return { promise, resolve };
}

function fulfilled<T>(value: T): PromiseLike<T> {
	return { then() {}, status: 'fulfilled', value } as any;
}

function screen(container: Element) {
	const text = (selector: string) => container.querySelector(selector)?.textContent ?? null;
	const title = (selector: string) => container.querySelector(selector)?.getAttribute('title');
	return {
		label: text('#label'),
		title: title('#label'),
		buttons: Array.from({ length: 10 }, (_, index) => text('#b' + index)).join(','),
		badge: text('#badge') + '|' + title('#badge'),
		rows: Array.from(container.querySelectorAll('li'), (row) => row.id).join(','),
		read: text('#read'),
	};
}

function expectScreen(container: Element, label: string, rows: string, read: string): void {
	expect(screen(container)).toEqual({
		label,
		title: label,
		buttons: Array(10).fill(label).join(','),
		badge: label + '|' + label,
		rows,
		read,
	});
}

function click(container: Element): void {
	flushSync(() => (container.querySelector('#b0') as HTMLButtonElement).click());
}

/**
 * Many committed waves, then a root-level hold (no boundary), its retry with the
 * held values, a superseded hold, and more waves. Every step would observe a
 * different leftover from an earlier wave: undo records, snapshots, captured
 * effects or refs, created-Block ownership, or the fixed-bag snapshot window.
 */
async function exerciseWaves(
	app: Fixture,
	container: Element,
	render: (props: object) => void,
	log: string[],
	refs: string[],
	track: (el: Element | null) => void,
	prefix: string,
): Promise<void> {
	const row2 = container.querySelector('#row-2');
	const span = container.querySelector('#label');
	for (let tick = 1; tick <= 4; tick++) {
		log.length = 0;
		flushSync(() => app.updateTick(tick));
		expectScreen(container, prefix + ':' + tick, 'row-1,row-2,row-3', 'r0');
		expect(log).toEqual(['unlayout:' + prefix + ':' + (tick - 1), 'layout:' + prefix + ':' + tick]);
	}
	expect(refs).toEqual(['attach:row-1', 'attach:row-2', 'attach:row-3']);

	const pending = deferred<string>();
	log.length = 0;
	render({ label: 'b', rows: [1, 3], promise: pending.promise, log, track });
	expectScreen(container, prefix + ':4', 'row-1,row-2,row-3', 'r0');
	expect(container.querySelector('#row-2')).toBe(row2);
	expect(container.querySelector('#label')).toBe(span);
	click(container);
	expect(log).toEqual(['click:' + prefix + ':4']);

	// The retry renders the held attempt's values again; every binding must
	// still write them over the restored screen.
	log.length = 0;
	await act(() => pending.resolve('r1'));
	expectScreen(container, 'b:4', 'row-1,row-3', 'r1');
	expect(log).toEqual(['cleanup:2', 'unlayout:' + prefix + ':4', 'layout:b:4']);
	expect(container.querySelector('#label')).toBe(span);
	expect(refs).toEqual(['attach:row-1', 'attach:row-2', 'attach:row-3', 'detach']);

	for (let tick = 5; tick <= 6; tick++) flushSync(() => app.updateTick(tick));
	const second = deferred<string>();
	log.length = 0;
	render({ label: 'c', rows: [3], promise: second.promise, log, track });
	render({ label: 'd', rows: [3], promise: second.promise, log, track });
	expectScreen(container, 'b:6', 'row-1,row-3', 'r1');
	expect(log).toEqual([]);
	await act(() => second.resolve('r2'));
	expectScreen(container, 'd:6', 'row-3', 'r2');
	expect(log).toEqual(['cleanup:1', 'unlayout:b:6', 'layout:d:6']);

	for (let tick = 7; tick <= 9; tick++) {
		log.length = 0;
		flushSync(() => app.updateTick(tick));
		expectScreen(container, 'd:' + tick, 'row-3', 'r2');
		expect(log).toEqual(['unlayout:d:' + (tick - 1), 'layout:d:' + tick]);
	}
	log.length = 0;
	click(container);
	expect(log).toEqual(['click:d:9']);
	expect(refs).toEqual(['attach:row-1', 'attach:row-2', 'attach:row-3', 'detach', 'detach']);
}

function tracker() {
	const refs: string[] = [];
	const track = (el: Element | null) => refs.push(el === null ? 'detach' : 'attach:' + el.id);
	return { refs, track };
}

// Committed waves hand their emptied root transaction to the same root's next
// wave. Loading the fixture compiler below imports octane/signals, which turns
// native reads on for the rest of this file, so these plain cases run first.
describe('root transactions across committed waves', () => {
	it('holds, retries and commits exactly after many ordinary commits', async () => {
		const app = plain as Fixture;
		const container = document.createElement('div');
		document.body.appendChild(container);
		const root = createRoot(container);
		const log: string[] = [];
		const { refs, track } = tracker();
		try {
			root.render(app.ReuseApp, {
				label: 'a',
				rows: [1, 2, 3],
				promise: fulfilled('r0'),
				log,
				track,
			});
			flushSync(() => {});
			expectScreen(container, 'a:0', 'row-1,row-2,row-3', 'r0');
			await exerciseWaves(
				app,
				container,
				(props) => flushSync(() => root.render(app.ReuseApp, props)),
				log,
				refs,
				track,
				'a',
			);
		} finally {
			log.length = 0;
			root.unmount();
			container.remove();
		}
		expect(log).toEqual(['unlayout:d:9', 'cleanup:3']);
	});

	it('keeps interleaved roots independent when one holds in the same drain', async () => {
		const app = plain as Fixture;
		const host = document.createElement('div');
		const mirrorHost = document.createElement('div');
		document.body.append(host, mirrorHost);
		const root = createRoot(host);
		const mirror = createRoot(mirrorHost);
		const log: string[] = [];
		const { track } = tracker();
		// A deletion cleanup runs inside the host's commit; it renders the mirror.
		const onCleanup = (id: number) =>
			mirror.render(app.Mirror, { label: 'cleanup:' + id, promise: fulfilled('ok') });
		try {
			root.render(app.ReuseApp, {
				label: 'm',
				rows: [1, 2],
				promise: fulfilled('r0'),
				log,
				track,
				onCleanup,
			});
			mirror.render(app.Mirror, { label: 'm:0', promise: fulfilled('ok') });
			flushSync(() => {});
			const paragraph = mirrorHost.querySelector('#mirror');
			for (let tick = 1; tick <= 3; tick++) {
				flushSync(() => {
					app.updateTick(tick);
					mirror.render(app.Mirror, { label: 'm:' + tick, promise: fulfilled('ok') });
				});
				expectScreen(host, 'm:' + tick, 'row-1,row-2', 'r0');
				expect(mirrorHost.querySelector('#mirror')).toBe(paragraph);
				expect(paragraph!.textContent).toBe('m:' + tick + '/ok');
			}

			// Both roots render in one drain; only the mirror suspends.
			const pending = deferred<string>();
			flushSync(() => {
				app.updateTick(4);
				mirror.render(app.Mirror, { label: 'm:4', promise: pending.promise });
			});
			expectScreen(host, 'm:4', 'row-1,row-2', 'r0');
			expect(paragraph!.textContent).toBe('m:3/ok');
			expect(paragraph!.getAttribute('title')).toBe('m:3');
			flushSync(() => app.updateTick(5));
			expectScreen(host, 'm:5', 'row-1,row-2', 'r0');
			expect(paragraph!.textContent).toBe('m:3/ok');

			await act(() => pending.resolve('late'));
			expect(mirrorHost.querySelector('#mirror')).toBe(paragraph);
			expect(paragraph!.textContent).toBe('m:4/late');
			expect(paragraph!.getAttribute('title')).toBe('m:4');

			flushSync(() =>
				root.render(app.ReuseApp, {
					label: 'm',
					rows: [1],
					promise: fulfilled('r0'),
					log,
					track,
					onCleanup,
				}),
			);
			expectScreen(host, 'm:5', 'row-1', 'r0');
			expect(mirrorHost.querySelector('#mirror')).toBe(paragraph);
			expect(paragraph!.textContent).toBe('cleanup:2/ok');
			for (let tick = 6; tick <= 7; tick++) {
				flushSync(() => {
					app.updateTick(tick);
					mirror.render(app.Mirror, { label: 'm:' + tick, promise: fulfilled('ok') });
				});
				expectScreen(host, 'm:' + tick, 'row-1', 'r0');
				expect(paragraph!.textContent).toBe('m:' + tick + '/ok');
			}
		} finally {
			root.unmount();
			mirror.unmount();
			host.remove();
			mirrorHost.remove();
		}
	});
});

describe.each([false, true])('root transactions with native reads (dev %s)', (dev) => {
	let fixture: (mode?: 'client' | 'server') => Fixture;
	beforeAll(async () => {
		const { loadCompiledFixtureSource } = await import('./_server-fixture');
		fixture = (mode = 'client') =>
			loadCompiledFixtureSource(`import 'octane/signals';\n${SOURCE}`, {
				id: `root-transaction-reuse-native-${dev}.tsrx`,
				mode,
				compileOptions: { dev, hmr: false },
			}) as unknown as Fixture;
	});

	it('holds, retries and commits exactly after many ordinary commits', async () => {
		const app = fixture();
		const container = document.createElement('div');
		document.body.appendChild(container);
		const root = createRoot(container);
		const log: string[] = [];
		const { refs, track } = tracker();
		try {
			root.render(app.ReuseApp, {
				label: 'a',
				rows: [1, 2, 3],
				promise: fulfilled('r0'),
				log,
				track,
			});
			flushSync(() => {});
			expectScreen(container, 'a:0', 'row-1,row-2,row-3', 'r0');
			await exerciseWaves(
				app,
				container,
				(props) => flushSync(() => root.render(app.ReuseApp, props)),
				log,
				refs,
				track,
				'a',
			);
		} finally {
			log.length = 0;
			root.unmount();
			container.remove();
		}
		expect(log).toEqual(['unlayout:d:9', 'cleanup:3']);
	});

	it('continues from an adopted server screen', async () => {
		const app = fixture();
		const server = fixture('server');
		const container = document.createElement('div');
		document.body.appendChild(container);
		const log: string[] = [];
		const { refs, track } = tracker();
		const props = { label: 'h', rows: [1, 2, 3], promise: fulfilled('r0'), log, track };
		container.innerHTML = renderToString(server.ReuseApp, props).html;
		const span = container.querySelector('#label');
		const errors: unknown[] = [];
		const root = hydrateRoot(container, app.ReuseApp, props, {
			onRecoverableError: (error) => errors.push(error),
		});
		try {
			flushSync(() => {});
			expect(container.querySelector('#label')).toBe(span);
			expectScreen(container, 'h:0', 'row-1,row-2,row-3', 'r0');
			await exerciseWaves(
				app,
				container,
				(next) => flushSync(() => root.render(app.ReuseApp, next)),
				log,
				refs,
				track,
				'h',
			);
			expect(container.querySelector('#label')).toBe(span);
			expect(errors).toEqual([]);
		} finally {
			root.unmount();
			container.remove();
		}
	});

	it('keeps interleaved roots independent when one holds in the same drain', async () => {
		const app = fixture();
		const host = document.createElement('div');
		const mirrorHost = document.createElement('div');
		document.body.append(host, mirrorHost);
		const root = createRoot(host);
		const mirror = createRoot(mirrorHost);
		const log: string[] = [];
		const { track } = tracker();
		// A deletion cleanup runs inside the host's commit; it renders the mirror.
		const onCleanup = (id: number) =>
			mirror.render(app.Mirror, { label: 'cleanup:' + id, promise: fulfilled('ok') });
		try {
			root.render(app.ReuseApp, {
				label: 'm',
				rows: [1, 2],
				promise: fulfilled('r0'),
				log,
				track,
				onCleanup,
			});
			mirror.render(app.Mirror, { label: 'm:0', promise: fulfilled('ok') });
			flushSync(() => {});
			const paragraph = mirrorHost.querySelector('#mirror');
			for (let tick = 1; tick <= 3; tick++) {
				flushSync(() => {
					app.updateTick(tick);
					mirror.render(app.Mirror, { label: 'm:' + tick, promise: fulfilled('ok') });
				});
				expectScreen(host, 'm:' + tick, 'row-1,row-2', 'r0');
				expect(mirrorHost.querySelector('#mirror')).toBe(paragraph);
				expect(paragraph!.textContent).toBe('m:' + tick + '/ok');
			}

			// Both roots render in one drain; only the mirror suspends.
			const pending = deferred<string>();
			flushSync(() => {
				app.updateTick(4);
				mirror.render(app.Mirror, { label: 'm:4', promise: pending.promise });
			});
			expectScreen(host, 'm:4', 'row-1,row-2', 'r0');
			expect(paragraph!.textContent).toBe('m:3/ok');
			expect(paragraph!.getAttribute('title')).toBe('m:3');
			flushSync(() => app.updateTick(5));
			expectScreen(host, 'm:5', 'row-1,row-2', 'r0');
			expect(paragraph!.textContent).toBe('m:3/ok');

			await act(() => pending.resolve('late'));
			expect(mirrorHost.querySelector('#mirror')).toBe(paragraph);
			expect(paragraph!.textContent).toBe('m:4/late');
			expect(paragraph!.getAttribute('title')).toBe('m:4');

			flushSync(() =>
				root.render(app.ReuseApp, {
					label: 'm',
					rows: [1],
					promise: fulfilled('r0'),
					log,
					track,
					onCleanup,
				}),
			);
			expectScreen(host, 'm:5', 'row-1', 'r0');
			expect(mirrorHost.querySelector('#mirror')).toBe(paragraph);
			expect(paragraph!.textContent).toBe('cleanup:2/ok');
			for (let tick = 6; tick <= 7; tick++) {
				flushSync(() => {
					app.updateTick(tick);
					mirror.render(app.Mirror, { label: 'm:' + tick, promise: fulfilled('ok') });
				});
				expectScreen(host, 'm:' + tick, 'row-1', 'r0');
				expect(paragraph!.textContent).toBe('m:' + tick + '/ok');
			}
		} finally {
			root.unmount();
			mirror.unmount();
			host.remove();
			mirrorHost.remove();
		}
	});
});
