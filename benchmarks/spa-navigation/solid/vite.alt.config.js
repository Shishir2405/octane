import { mergeConfig } from 'vite';
import base from './vite.config.js';

// Scratch A/B only: the pre-#983 unminified build, served from dist-alt.
export default mergeConfig(base, { build: { outDir: 'dist-alt', minify: false } });
