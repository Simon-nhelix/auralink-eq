import { readFile } from "node:fs/promises";

const allowedLicenses = new Set([
  "Apache-2.0",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "ISC",
  "MIT",
]);

const lock = JSON.parse(
  await readFile(new URL("../package-lock.json", import.meta.url), "utf8"),
);

if (lock.lockfileVersion !== 3 || typeof lock.packages !== "object") {
  throw new Error("Expected an npm lockfileVersion 3 packages map");
}

const rejected = [];
const counts = new Map();

for (const [packagePath, metadata] of Object.entries(lock.packages)) {
  if (packagePath === "") continue;

  const license = metadata.license;
  if (typeof license !== "string" || !allowedLicenses.has(license)) {
    rejected.push({
      packagePath,
      version: metadata.version ?? "unknown",
      license: license ?? "UNDECLARED",
    });
    continue;
  }

  counts.set(license, (counts.get(license) ?? 0) + 1);
}

if (rejected.length > 0) {
  console.error("Dependency licenses require manual review:");
  for (const item of rejected) {
    console.error(
      `- ${item.packagePath}@${item.version}: ${item.license}`,
    );
  }
  process.exitCode = 1;
} else {
  const summary = [...counts.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([license, count]) => `${license}=${count}`)
    .join(", ");
  console.log(`Dependency license check passed (${summary})`);
}
