const fs = require("fs");

if (!fs.existsSync("dist/build.json")) {
  process.stderr.write("fixture has not been built\n");
  process.exit(2);
}

let versionIndex = 2;
if (process.argv[2] === "--count-effect") {
  const counterPath = process.argv[3];
  if (!counterPath) {
    process.stderr.write("effect counter path is required\n");
    process.exit(3);
  }
  let count = 0;
  try { count = Number(fs.readFileSync(counterPath, "utf8")) || 0; } catch (error) {
    if (!error || error.code !== "ENOENT") throw error;
  }
  fs.mkdirSync(require("path").dirname(counterPath), { recursive: true });
  fs.writeFileSync(counterPath, `${count + 1}\n`, { flag: "w" });
  versionIndex = 4;
}

if (process.argv[versionIndex] !== "--version") {
  process.stderr.write("usage: node cli.js [--count-effect path] --version\n");
  process.exit(3);
}

if (fs.existsSync("source-only-uncommitted.txt")) {
  process.stderr.write("test execution leaked the source working directory\n");
  process.exit(4);
}

process.stdout.write("canonical-qa-fixture/1.0.0\n");
