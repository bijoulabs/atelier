// Minimal stand-in for the full "shiki" package, aliased in by esbuild.
// Only what @pierre/diffs actually touches: the core highlighter, the
// pure-JS regex engine (no WASM), and the three grammars an atelier page
// diff can contain. Everything else in shiki's bundled surface stays out
// of the bundle.
import { createCssVariablesTheme, createHighlighterCore } from '@shikijs/core';
import { createJavaScriptRegexEngine } from '@shikijs/engine-javascript';

export {
  getTokenStyleObject,
  stringifyTokenStyle,
} from '@shikijs/core';
export { createCssVariablesTheme, createJavaScriptRegexEngine };

// The subset of shiki's bundledLanguages the diff page can need. html
// pulls its embedded css/javascript grammars through the imports below.
export const bundledLanguages = {
  html: () => import('@shikijs/langs/html'),
  css: () => import('@shikijs/langs/css'),
  javascript: () => import('@shikijs/langs/javascript'),
  json: () => import('@shikijs/langs/json'),
};

// @pierre/diffs only reaches this on preferredHighlighter === 'shiki-wasm',
// which atelier never requests.
export function createOnigurumaEngine() {
  throw new Error('wasm engine not bundled in atelier');
}

// pierre calls createHighlighter({ themes: [], langs: ['text'], engine });
// core treats text/plain as grammar-less built-ins, and real grammars and
// themes are attached later via loadLanguage/loadTheme, so starting empty
// matches the full package's observable behavior.
export function createHighlighter(options) {
  return createHighlighterCore({ ...options, langs: [], themes: [] });
}

// Re-exported by @pierre/diffs' index but unused by the FileDiff path;
// esbuild tree-shakes it out unless something unexpectedly pulls it in.
export function codeToHtml() {
  throw new Error('codeToHtml not bundled in atelier');
}
