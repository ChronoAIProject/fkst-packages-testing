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
  fs.mkdirSync(counterPath, { recursive: true });
  const recordPath = require("path").join(counterPath,
    `invocation-${process.pid}-${require("crypto").randomBytes(8).toString("hex")}.json`);
  fs.writeFileSync(recordPath, `${JSON.stringify({ pid: process.pid, argv: process.argv.slice(2) })}\n`, {
    flag: "wx",
  });
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
