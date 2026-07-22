const fs = require("fs");

fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync(
  "dist/build.json",
  JSON.stringify({ schema: "canonical-qa.build.v1", status: "ready" }) + "\n",
);
