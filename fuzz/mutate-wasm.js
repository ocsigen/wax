// Seeded byte-level mutator for wasm binaries, driving the wasm-binary fuzzer
// (mutate-wasm.sh).
//
//   node mutate-wasm.js <file.wasm> [seed]   (mutated bytes to stdout)
//
// Tests the binary *reader* (wax -i wasm) on malformed input — a surface no
// other fuzzer reaches (smith/the corpus are always valid; mutate-wax/-wat feed
// text). The bugs here are decoder robustness: truncated sections, bad LEB128,
// out-of-range counts/indices, unknown opcodes. So we corrupt bytes rather than
// structure, but preserve the 8-byte magic+version header so most mutants get
// past the magic check and into the section parser, where the interesting
// crashes live. One mutation per run, chosen deterministically from the seed.

const fs = require("fs");

const file = process.argv[2];
let seed = (parseInt(process.argv[3] || "0", 10) * 2 + 1) >>> 0;
const rnd = () => {
  seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
  return seed >>> 1;
};

let b = fs.readFileSync(file);
const n = b.length;
const base = Math.min(8, n); // keep magic+version so the body parser is reached
if (n <= base) {
  process.stdout.write(b);
  process.exit(0);
}
const pos = () => base + (rnd() % (n - base));

switch (rnd() % 6) {
  case 0: {
    // flip bits in a few body bytes
    const k = 1 + (rnd() % 4);
    for (let i = 0; i < k; i++) b[pos()] ^= 1 + (rnd() % 255);
    break;
  }
  case 1:
    // truncate the body at a random point
    b = b.subarray(0, base + (rnd() % (n - base)));
    break;
  case 2:
    // pin a body byte to an extreme (0x00 / 0x7f / 0x80 / 0xff — LEB edges)
    b[pos()] = [0x00, 0x7f, 0x80, 0xff][rnd() % 4];
    break;
  case 3: {
    // insert random bytes
    const p = pos();
    const k = 1 + (rnd() % 8);
    const ins = Buffer.allocUnsafe(k);
    for (let i = 0; i < k; i++) ins[i] = rnd() % 256;
    b = Buffer.concat([b.subarray(0, p), ins, b.subarray(p)]);
    break;
  }
  case 4: {
    // delete a run of bytes
    const p = pos();
    const k = 1 + (rnd() % 8);
    b = Buffer.concat([b.subarray(0, p), b.subarray(Math.min(n, p + k))]);
    break;
  }
  default: {
    // overwrite a run with 0xff (large LEB / bogus count)
    const p = pos();
    const k = 1 + (rnd() % 6);
    for (let i = 0; i < k && p + i < b.length; i++) b[p + i] = 0xff;
    break;
  }
}
process.stdout.write(b);
