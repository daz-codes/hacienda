import {existsSync, readFileSync, readdirSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const source = join(root, "packages", "morpheus");
const destinations = [
  join(root, "lib", "lunula", "assets"),
  ...readdirSync(join(root, "examples"), {withFileTypes: true})
    .filter(entry => entry.isDirectory())
    .map(entry => join(root, "examples", entry.name, "public", "assets"))
    .filter(existsSync)
];
const files = new Map([
  [join("src", "morpheus.js"), "morpheus.js"],
  [join("src", "idiomorph.esm.js"), "idiomorph.esm.js"],
  ["LICENSE", "MORPHEUS-LICENSE.txt"],
  ["IDIOMORPH-LICENSE.txt", "IDIOMORPH-LICENSE.txt"]
]);
const stale = [];

for (const destination of destinations) {
  for (const [input, output] of files) {
    const sourcePath = join(source, input);
    const destinationPath = join(destination, output);
    if (!existsSync(destinationPath) || !readFileSync(destinationPath).equals(readFileSync(sourcePath))) {
      stale.push(destinationPath);
    }
  }
}

if (stale.length > 0) {
  console.error(`Vendored Morpheus assets are stale:\n${stale.join("\n")}`);
  process.exit(1);
}

console.log("Vendored Morpheus assets are current.");
