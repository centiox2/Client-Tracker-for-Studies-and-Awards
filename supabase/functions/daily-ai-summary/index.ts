import { generateReport, ReportGenerationError } from "./generate.ts";
const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
async function rpc(name: string, body: unknown) {
  const result = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  if (!result.ok) throw new Error("database_request_failed");
  const text = await result.text();
  return text ? JSON.parse(text) : null;
}
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  const token = req.headers.get("x-summary-job-token");
  if (!token || token.length !== 64) {
    return new Response("Unauthorized", { status: 401 });
  }
  let manualJob: string | null = null;
  try {
    const body = await req.json();
    if (body.manual_job_id !== undefined) {
      if (
        typeof body.manual_job_id !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
          body.manual_job_id,
        )
      ) {
        return new Response("Invalid job", { status: 400 });
      }
      manualJob = body.manual_job_id;
    }
  } catch {
    return new Response("Invalid request", { status: 400 });
  }
  const run = crypto.randomUUID();
  let claimed = false;
  try {
    const job = await rpc("ai_summary_claim_job", {
      p_job_token: token,
      p_run_id: run,
      p_manual_job: manualJob,
    });
    if (!job) return Response.json({ status: "skipped" });
    claimed = true;
    const content = await generateReport(job);
    await rpc("ai_summary_finish", { p_run_id: run, p_content: content });
    return Response.json({ status: "ready" });
  } catch (error) {
    // No prompts, API keys, provider response bodies or business records in logs/errors.
    const code = error instanceof ReportGenerationError
      ? error.code
      : "generation_failed";
    if (claimed) {
      try {
        await rpc("ai_summary_finish", { p_run_id: run, p_error: code });
      } catch { /* lease permits bounded retry */ }
    }
    return Response.json({ status: claimed ? "failed" : "unauthorized" }, {
      status: claimed ? 502 : 401,
    });
  }
});
