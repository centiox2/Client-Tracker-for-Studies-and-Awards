export const pages = [
  "weekly_tracker",
  "revenue",
  "applications",
  "daily_reports",
  "team_todo",
  "staff",
];
export const schema = {
  type: "object",
  properties: {
    brief: { type: "string" },
    highlights: { type: "array", items: { type: "string" } },
    risks: { type: "array", items: { type: "string" } },
    actions: { type: "array", items: { type: "string" } },
    sections: {
      type: "array",
      items: {
        type: "object",
        properties: {
          page: { type: "string", enum: pages },
          title: { type: "string" },
          body: { type: "string" },
          findings: { type: "array", items: { type: "string" } },
          next_steps: { type: "array", items: { type: "string" } },
        },
        required: ["page", "title", "body", "findings", "next_steps"],
      },
    },
  },
  required: ["brief", "highlights", "risks", "actions", "sections"],
};
export function validateSummary(value: unknown) {
  const v = value as Record<string, unknown>;
  const text = (x: unknown, max: number) =>
    typeof x === "string" && x.trim().length > 0 && x.length <= max;
  if (!v || !text(v.brief, 1000)) throw new Error("invalid_summary");
  for (const key of ["highlights", "risks", "actions"]) {
    const list = v[key];
    if (
      !Array.isArray(list) || list.length > 8 ||
      !list.every((x) => text(x, 1000))
    ) throw new Error("invalid_summary");
  }
  const sections = v.sections;
  if (!Array.isArray(sections) || sections.length !== pages.length) {
    throw new Error("invalid_summary");
  }
  const seen = new Set();
  for (const section of sections) {
    if (
      !section || !pages.includes(section.page) || seen.has(section.page) ||
      !text(section.title, 100) || !text(section.body, 3000)
    ) throw new Error("invalid_summary");
    for (const field of ["findings", "next_steps"]) {
      const list = section[field];
      if (
        list !== undefined &&
        (!Array.isArray(list) || list.length > 6 ||
          !list.every((x: unknown) => text(x, 800)))
      ) throw new Error("invalid_summary");
    }
    seen.add(section.page);
  }
  // Project onto expected fields only; don't persist arbitrary model fields.
  return {
    brief: v.brief,
    highlights: v.highlights,
    risks: v.risks,
    actions: v.actions,
    sections: sections.map((s) => ({
      page: s.page,
      title: s.title,
      body: s.body,
      findings: s.findings ?? [],
      next_steps: s.next_steps ?? [],
    })),
  };
}
