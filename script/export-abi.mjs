#!/usr/bin/env node
/**
 * Exports the ABIs the Spin worker consumes.
 *
 * Emits BOTH:
 *   contracts/abi/<Name>.json          for humans, auditors and external tools
 *   backend/src/modules/spin/chain/<name>.abi.ts   for the worker
 *
 * TypeScript rather than JSON on the backend side, for two concrete reasons:
 * the repo's tsconfig has no `resolveJsonModule`, and `nest build` does not copy
 * .json out of src into dist, so a JSON import would compile fine and then fail
 * at runtime in production. A .ts file has neither problem, and `as const` gives
 * viem full type inference on function names and argument tuples.
 *
 * The worker reads a committed artifact rather than importing from `out/`, which
 * works precisely because SpinAssignment is immutable: its ABI is frozen the
 * moment it ships, so there is nothing to drift.
 *
 *   node script/export-abi.mjs
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const jsonOut = join(root, 'abi');
const tsOut = join(root, '..', 'backend', 'src', 'modules', 'spin', 'chain');

mkdirSync(jsonOut, { recursive: true });
mkdirSync(tsOut, { recursive: true });

const header = (name) => `// GENERATED FILE — DO NOT EDIT BY HAND.
// Regenerate with: node script/export-abi.mjs   (in the contracts repo)
//
// ABI for ${name}. Safe to freeze in source because the contract is immutable:
// there is no proxy and no upgrade path, so this ABI can never drift from the
// deployed bytecode. A new version means a new deployment and a new address,
// resolved through SpinRegistry.
`;

for (const name of ['SpinAssignment', 'SpinRegistry']) {
  const artifact = JSON.parse(
    readFileSync(join(root, 'out', `${name}.sol`, `${name}.json`), 'utf8'),
  );
  const abi = artifact.abi;

  writeFileSync(join(jsonOut, `${name}.json`), JSON.stringify(abi, null, 2) + '\n');

  const constName =
    name.replace(/([a-z])([A-Z])/g, '$1_$2').toUpperCase() + '_ABI';
  const file = name.replace(/([a-z])([A-Z])/g, '$1-$2').toLowerCase();

  writeFileSync(
    join(tsOut, `${file}.abi.ts`),
    `${header(name)}\nexport const ${constName} = ${JSON.stringify(abi, null, 2)} as const;\n`,
  );

  const fns = abi.filter((e) => e.type === 'function').length;
  const events = abi.filter((e) => e.type === 'event').length;
  console.log(
    `${name}: ${fns} functions, ${events} events -> abi/${name}.json + backend .../${file}.abi.ts`,
  );
}
