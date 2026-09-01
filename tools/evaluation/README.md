# Evaluation harness

The evaluator compares a reviewed expected timeline with an agent-produced timeline and emits machine-readable JSON.

```sh
node --test evaluate.test.mjs
node evaluate.mjs expected.json actual.json > result.json
```

Measured fields:

- Transcript character error rate after Unicode normalization
- Transcript start timestamp mean and p95 absolute offset
- Key-frame precision and recall using interval IoU
- Decision and action-item precision, recall, and F1
- Runtime and recovery fields passed through from the actual result

Evaluation fixtures must be synthetic, explicitly consented, or otherwise rights-cleared. Do not commit real confidential meetings.
