'use strict';

const fs = require('fs');

const behavior = process.argv[2];
process.stdin.resume();
process.stdin.on('end', () => {
  if (behavior === 'success' || behavior === 'success-wrong-model' || behavior === 'success-no-model') {
    if (behavior === 'success-wrong-model') process.stderr.write('model: attacker-controlled\n');
    process.stdout.write(fs.readFileSync(process.argv[3], 'utf8'));
  } else if (behavior === 'refusal') {
    process.stdout.write('{"failure":"refusal"}\n');
  } else if (behavior === 'budget') {
    process.stdout.write('{"failure":"budget-exhausted"}\n');
  } else if (behavior === 'malformed') {
    process.stdout.write('not json');
  } else if (behavior === 'truncate') {
    process.stdout.write('x'.repeat(16384));
  } else if (behavior === 'nonzero') {
    process.stderr.write('raw secret stderr must not escape');
    process.exitCode = 9;
  } else if (behavior === 'wait') {
    setTimeout(() => process.stdout.write('{}\n'), 10000);
  }
});
