const solc = require('solc');
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.sol')) out.push(p);
  }
  return out;
}

const sources = {};
// Project sources + tests under their project-relative names.
for (const f of [...walk(path.join(ROOT, 'src')), ...walk(path.join(ROOT, 'test'))]) {
  sources[path.relative(ROOT, f)] = { content: fs.readFileSync(f, 'utf8') };
}
// forge-std under the remapped virtual prefix "forge-std/".
for (const f of walk(path.join(ROOT, '../lib/forge-std/src'))) {
  sources['forge-std/' + path.relative(path.join(ROOT, '../lib/forge-std/src'), f)] = {
    content: fs.readFileSync(f, 'utf8'),
  };
}

const input = {
  language: 'Solidity',
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input)));
let fatal = false;
for (const e of out.errors || []) {
  if (e.severity === 'error') {
    fatal = true;
    console.log(`[error] ${e.formattedMessage.trim()}`);
  }
}
if (fatal) {
  console.log('COMPILE_FAILED');
  process.exit(1);
}

// Emit artifacts for the runtime harness.
const want = [
  'GhoFacilitatorWindDownTrigger', 'GhoFacilitatorCredentialProvider',
  'MockSealedRegistry', 'MockLatchTrigger', 'MockGhoToken',
];
const artifacts = {};
let testContracts = 0;
for (const [file, contracts] of Object.entries(out.contracts || {})) {
  for (const [name, c] of Object.entries(contracts)) {
    if (want.includes(name)) artifacts[name] = { abi: c.abi, bin: c.evm.bytecode.object };
    if (file.startsWith('test/') && name.endsWith('Test')) testContracts++;
  }
}
fs.writeFileSync(path.join(ROOT, 'script', 'artifacts.json'), JSON.stringify(artifacts));
console.log(`sources compiled: ${Object.keys(sources).length}`);
console.log(`test contracts compiled: ${testContracts}`);
console.log(`artifacts emitted: ${Object.keys(artifacts).length}`);
console.log('COMPILE_SUCCESS');
