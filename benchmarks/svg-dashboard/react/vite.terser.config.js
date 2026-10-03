import { mergeConfig } from 'vite';
import base from './vite.config.js';

// Scratch A/B only: the pre-#983 terser build, served from dist-terser.
export default mergeConfig(base, {
	build: {
		outDir: 'dist-terser',
		minify: 'terser',
		terserOptions: { compress: { passes: 2, toplevel: true }, mangle: { toplevel: true } },
	},
});
