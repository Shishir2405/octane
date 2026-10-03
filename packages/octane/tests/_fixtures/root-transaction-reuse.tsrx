import { use, useLayoutEffect, useState } from 'octane';

let setTick;
export function updateTick(value) {
	setTick(value);
}

function Row(props) @{
	useLayoutEffect(
		() => () => {
			props.log.push('cleanup:' + props.id);
			props.onCleanup?.(props.id);
		},
		[],
	);
	<li id={'row-' + props.id} ref={props.track}>{String(props.id)}</li>
}

function Badge(props) @{
	<b id="badge" title={props.label}>{props.label as string}</b>
}

function Reader(props) @{
	const value = use(props.promise);
	<output id="read">{value as string}</output>
}

// The root template has more bindings than the fixed-arity bag factories, so
// its writes take the generic object snapshot path; Badge keeps a fixed bag.
export function ReuseApp(props) @{
	const [tick, set] = useState(0);
	setTick = set;
	const label = props.label + ':' + tick;
	useLayoutEffect(() => {
		props.log.push('layout:' + label);
		return () => props.log.push('unlayout:' + label);
	}, [label]);
	<main>
		<span id="label" title={label}>{label as string}</span>
		<button
			id="b0"
			title={label}
			onClick={() => props.log.push('click:' + label)}
		>{label as string}</button>
		<button id="b1" title={label}>{label as string}</button>
		<button id="b2" title={label}>{label as string}</button>
		<button id="b3" title={label}>{label as string}</button>
		<button id="b4" title={label}>{label as string}</button>
		<button id="b5" title={label}>{label as string}</button>
		<button id="b6" title={label}>{label as string}</button>
		<button id="b7" title={label}>{label as string}</button>
		<button id="b8" title={label}>{label as string}</button>
		<button id="b9" title={label}>{label as string}</button>
		<Badge label={label} />
		<ul>
			@for (const id of props.rows; key id) {
				<Row id={id} log={props.log} track={props.track} onCleanup={props.onCleanup} />
			}
		</ul>
		<Reader promise={props.promise} />
	</main>
}

export function Mirror(props) @{
	const value = use(props.promise);
	<p id="mirror" title={props.label}>{props.label + '/' + value as string}</p>
}
