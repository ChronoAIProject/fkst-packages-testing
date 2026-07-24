const fs = require("fs");

if (!fs.existsSync("dist/build.json")) {
  process.stderr.write("fixture has not been built\n");
  process.exit(2);
}

if (process.argv[2] !== "--version") {
  process.stderr.write("usage: node cli.js --version\n");
  process.exit(3);
}

if (fs.existsSync("source-only-uncommitted.txt")) {
  process.stderr.write("test execution leaked the source working directory\n");
  process.exit(4);
}

process.stdout.write("canonical-qa-fixture/1.0.0\n");
