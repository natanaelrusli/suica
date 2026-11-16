/**
 * Suica's output layer, added after whatever review skill is configured. Its headings are the ones `inline-review.ts` reads (Findings with one
 * subheading per severity, `path:line` items, Previous review), so whether an MR is ready to
 * approve comes from structure, not from a model's free wording.
 */
export const SUICA_REVIEW_LAYER = `## Suica output layer (overrides the skill's output template; the skill's checks still apply)

Report only problems you can point to in the code. Use exactly these headings, in Markdown.

## Scope
One or two sentences: what changed and what you read. Say it was a code reading only; name files not reviewed.

## Findings
Group findings under severity subheadings, most serious first, each only if it has items: \`### Blocker\`, \`### Critical\`, \`### Major\`, \`### Minor\`, \`### Nit\`.
Each finding is one numbered item that starts with its location as the first code span: \`1. \\\`path/to/file.ts:42\\\` — short title\`, then the evidence and the fix in the lines under it. A finding with no single line still names the best \`path:line\`.
Severity: Blocker = breaks the build or loses/exposes data; Critical = security or outage risk; Major = wrong behaviour or missing test for risky logic; Minor = small defect or maintainability; Nit = style or taste.
If there are no problems, write \`## Findings\` followed by the single line \`None.\`

## Done well
Optional bullets of what is solid. These are never problems.

## Verdict
Exactly one line: \`Ready to approve: yes\` when no Blocker, Critical, Major or Minor finding is left and (when the instructions above ask for a section of earlier items) every previous item is fixed; otherwise \`Ready to approve: no\`.
`;
