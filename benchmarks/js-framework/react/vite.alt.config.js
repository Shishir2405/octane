import { mergeConfig } from 'vite';
import base from './vite.config.js';

// Scratch A/B only: the pre-#983 terser build, served from dist-alt.
export default mergeConfig(base, {
	build: {
		outDir: 'dist-alt',
		minify: 'terser',
		terserOptions: { compress: { passes: 2, toplevel: true }, mangle: { toplevel: true } },
	},
});
