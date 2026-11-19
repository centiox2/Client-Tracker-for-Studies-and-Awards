import {
  generateReport,
  prepareReportInput,
  ReportGenerationError,
} from "./generate.ts";
import { pages } from "./summary.ts";
const job = {
  model: "gemini-test",
  key: "unit-test-key-never-log",
  snapshot: { total: 3 },
};
const report = {
  brief: "Recorded totals.",
  highlights: [],
  risks: [],
  actions: [],
  sections: pages.map((page) => ({
    page,
    title: page,
    body: "Recorded data only.",
  })),
};
const success = () =>
  Response.json({
    candidates: [{
      finishReason: "STOP",
      content: { parts: [{ text: JSON.stringify(report) }] },
    }],
  });
function assert(value: boolean) {
  if (!value) throw new Error("assertion failed");
}
Deno.test("retries temporary overload with bounded backoff, then validates the report", async () => {
  let calls = 0;
  const waits: number[] = [];
  const result = await generateReport(
    job,
    async () =>
      ++calls < 3
        ? new Response("private provider details", { status: 503 })
        : success(),
    async (ms) => {
      waits.push(ms);
    },
  );
  assert(calls === 3);
  assert(waits.join(",") === "2000,4000");
  assert(result.brief === report.brief);
});
Deno.test("persistent overload stops after three attempts and returns a safe error", async () => {
  let calls = 0;
  try {
    await generateReport(job, async () => {
      calls++;
      return new Response(job.key, { status: 503 });
    }, async () => {});
    throw new Error("expected failure");
  } catch (e) {
    assert(e instanceof ReportGenerationError);
    assert(
      (e as ReportGenerationError).code === "gemini_temporarily_unavailable",
    );
    assert(!String(e).includes(job.key));
    assert(calls === 3);
  }
});
for (
  const [status, code] of [
    [401, "gemini_key_rejected"],
    [403, "gemini_key_rejected"],
    [429, "gemini_quota_exceeded"],
    [404, "gemini_model_unavailable"],
    [400, "gemini_request_invalid"],
  ] as const
) {
  Deno.test(`does not retry non-transient HTTP ${status}`, async () => {
    let calls = 0;
    try {
      await generateReport(job, async () => {
        calls++;
        return new Response("private", { status });
      }, async () => {});
      throw new Error("expected failure");
    } catch (e) {
      assert(e instanceof ReportGenerationError && e.code === code);
      assert(calls === 1);
    }
  });
}
Deno.test("retries a network timeout and accepts the successful retry", async () => {
  let calls = 0;
  const result = await generateReport(job, async () => {
    if (++calls === 1) throw new DOMException("timeout", "TimeoutError");
    return success();
  }, async () => {});
  assert(calls === 2);
  assert(result.sections.length === pages.length);
});
Deno.test("incomplete and malformed reports are never published", async () => {
  for (
    const value of [{ candidates: [{ finishReason: "MAX_TOKENS" }] }, {
      candidates: [{
        finishReason: "STOP",
        content: { parts: [{ text: "{}" }] },
      }],
    }]
  ) {
    let rejected = false;
    let calls = 0;
    try {
      await generateReport(
        job,
        async () => {
          calls++;
          return Response.json(value);
        },
        async () => {},
      );
    } catch (e) {
      rejected = e instanceof ReportGenerationError;
    }
    assert(rejected);
    assert(calls === 3);
  }
});

Deno.test("recovers from an invalid report and token cutoff with a compact retry", async () => {
  const requests: string[] = [];
  const result = await generateReport(job, async (_, options) => {
    requests.push(String(options?.body));
    switch (requests.length) {
      case 1:
        return Response.json({
          candidates: [{
            finishReason: "STOP",
            content: {
              parts: [{ text: JSON.stringify({ ...report, sections: [] }) }],
            },
          }],
        });
      case 2:
        return Response.json({ candidates: [{ finishReason: "MAX_TOKENS" }] });
      default:
        return success();
    }
  }, async () => {});
  assert(result.sections.length === pages.length);
  assert(requests.length === 3);
  assert(JSON.parse(requests[0]).generationConfig.maxOutputTokens === 6000);
  assert(JSON.parse(requests[1]).generationConfig.maxOutputTokens === 12000);
  assert(requests[1].includes("at most one item per list"));
});

Deno.test("provider safety blocks are not retried", async () => {
  let calls = 0;
  try {
    await generateReport(job, async () => {
      calls++;
      return Response.json({ promptFeedback: { blockReason: "SAFETY" } });
    });
    throw new Error("expected a blocked report to fail");
  } catch (error) {
    assert(
      error instanceof ReportGenerationError &&
        error.code === "gemini_incomplete",
    );
    assert(calls === 1);
  }
});

Deno.test("model input uses currency units and excludes storage fields without mutating the recorded snapshot", () => {
  const snapshot = {
    revenue: {
      today_cents: 1500000,
      month_net_cents: 39780000,
      currency: "KSh",
      amount_note: "storage note",
    },
  };
  const clean = prepareReportInput(snapshot);
  const revenue = clean.revenue as Record<string, unknown>;
  assert(revenue.today_amount === 15000 && revenue.month_net_amount === 397800);
  assert(!("today_cents" in revenue) && !("amount_note" in revenue));
  assert(snapshot.revenue.today_cents === 1500000);
});

Deno.test("keeps names and output labels out of Gemini input", () => {
  const input = prepareReportInput({
    staff: {
      active: 6,
      activity: [{
        name: "Private Person",
        outputs: [{ label: "Private label", count: 1 }],
      }],
    },
  });
  assert(!JSON.stringify(input).includes("Private"));
  assert(
    (input.staff as Record<string, unknown>).people_with_recorded_activity ===
      1,
  );
});
