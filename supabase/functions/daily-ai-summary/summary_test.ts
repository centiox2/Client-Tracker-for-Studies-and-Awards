import { pages, validateSummary } from "./summary.ts";
function assert(ok: boolean) {
  if (!ok) throw new Error("Assertion failed");
}
const sample = () => ({
  brief: "Recorded activity today.",
  highlights: ["One recorded fact."],
  risks: [],
  actions: [],
  sections: pages.map((page) => ({
    page,
    title: page,
    body: "Only aggregate recorded data.",
  })),
});
Deno.test("accepts complete summary and strips unrecognized fields", () => {
  const v = validateSummary({ ...sample(), key: "must not persist" });
  assert(!("key" in v));
  assert(v.sections.length === pages.length);
});
Deno.test("rejects missing, duplicate and excessive sections", () => {
  for (
    const sections of [
      [],
      [...sample().sections, sample().sections[0]],
      sample().sections.map(() => sample().sections[0]),
    ]
  ) {
    let rejected = false;
    try {
      validateSummary({ ...sample(), sections });
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});
Deno.test("rejects malformed and unbounded output", () => {
  for (
    const value of [
      null,
      {},
      { ...sample(), brief: "" },
      { ...sample(), brief: "a".repeat(1001) },
      { ...sample(), actions: ["a".repeat(1001)] },
      { ...sample(), risks: Array(9).fill("x") },
    ]
  ) {
    let rejected = false;
    try {
      validateSummary(value);
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});

Deno.test("detailed findings are retained and legacy reports remain valid", () => {
  const detailed = sample();
  const result = validateSummary({
    ...detailed,
    sections: detailed.sections.map((s) => ({
      ...s,
      findings: ["Recorded evidence"],
      next_steps: ["Review evidence"],
    })),
  });
  assert(result.sections[0].findings[0] === "Recorded evidence");
  assert(validateSummary(sample()).sections[0].findings.length === 0);
});
Deno.test("unbounded or malformed detailed findings are rejected", () => {
  for (const findings of ["invalid", Array(7).fill("x"), ["x".repeat(801)]]) {
    let rejected = false;
    try {
      validateSummary({
        ...sample(),
        sections: sample().sections.map((s) => ({ ...s, findings })),
      });
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});
