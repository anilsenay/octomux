Vendored from microsoft/playwright @ 07c7069 (Apache-2.0, see LICENSE):
packages/injected/src/{ariaSnapshot,ariaSnapshotDistiller,roleUtils,domUtils}.ts and
packages/isomorphic/{ariaSnapshot,ariaSnapshotRenderer,stringUtils,cssTokenizer,yaml}.ts.
Only change: `@isomorphic/*` imports point to ../isomorphic. Used by src/browser.js (the Octomux browser's page
snapshot, bundled to Resources/editor/browser.js).
