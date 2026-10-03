import { describe, expect, it } from 'vitest';
import { flushSync } from '../src/index.js';
import { flushEffects, mount } from './_helpers';
import {
	App,
	bump,
	rerenderShell,
	switchToChildren,
} from './_fixtures/context-children-switch.tsrx';

// A value slot can host a plain render function and later the compiler's element
// children in its place. The slot keeps its subtree across that switch, and from
// then on an identical children function lets the slot skip its body. A context
// change must still reach the consumers that subtree already held.
describe('a value slot that switches from a render function to element children', () => {
	it('keeps its existing context consumers live', () => {
		const r = mount(App);
		flushEffects();
		expect(r.find('.consumer').textContent).toBe('0');

		flushSync(() => bump());
		expect(r.find('.consumer').textContent).toBe('1');

		flushSync(() => switchToChildren());
		expect(r.find('.consumer').textContent).toBe('1');

		flushSync(() => bump());
		expect(r.find('.consumer').textContent).toBe('2');

		// The same children again, with a context change in the same commit.
		flushSync(() => {
			rerenderShell();
			bump();
		});
		expect(r.find('.consumer').textContent).toBe('3');
		r.unmount();
	});
});
