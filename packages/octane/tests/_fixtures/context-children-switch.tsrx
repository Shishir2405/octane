import { createContext, use, useState } from 'octane';

const Ctx = createContext(0);

let bumpValue: (() => void) | null = null;
let showChildren: (() => void) | null = null;
let rerender: (() => void) | null = null;

export function bump(): void {
	bumpValue!();
}
export function switchToChildren(): void {
	showChildren!();
}
export function rerenderShell(): void {
	rerender!();
}

function Consumer() @{
	const value = use(Ctx);
	<span class="consumer">{String(value)}</span>
}

// A plain render function: a value child the slot calls, not compiler children.
function renderConsumer() @{
	<Consumer />
}

// Renders whichever function it is handed as a value child.
function Frame(props: { body: unknown }) @{
	<div class="frame">{props.body}</div>
}

// Keeps the first children function it receives, so later renders hand the slot
// the identical children.
function Shell(props: { compiled: boolean; tick: number; children?: any }) @{
	const [children] = useState(() => props.children);
	<Frame body={props.compiled ? children : renderConsumer} />
}

export function App() @{
	const [value, setValue] = useState(0);
	const [compiled, setCompiled] = useState(false);
	const [tick, setTick] = useState(0);
	bumpValue = () => setValue((v) => v + 1);
	showChildren = () => setCompiled(true);
	rerender = () => setTick((t) => t + 1);
	<Ctx value={value}>
		<Shell compiled={compiled} tick={tick}>
			<Consumer />
		</Shell>
	</Ctx>
}
