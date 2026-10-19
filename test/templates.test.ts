import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  DEFAULT_TEMPLATES,
  TemplateError,
  describeFindings,
  escapeMarkdown,
  loadTemplates,
  markdownLink,
  renderTemplate,
  validateTemplate,
} from "../src/teams/templates.ts";
import { TEMPLATE_NAMES } from "../src/teams/types.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDir(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-tpl-"));
  folders.push(folder);
  return folder;
}

const values = {
  "mr.title": "Add thing",
  "mr.url": "https://gitlab.example/g/p/-/merge_requests/7",
  "mr.link": "[Add thing](https://gitlab.example/g/p/-/merge_requests/7)",
  "mr.iid": "7",
  "mr.project": "g/p",
  "person.name": "Alice",
  "owner.name": "Nata",
  "review.findings": "",
};

describe("validateTemplate", () => {
  it("accepts known placeholders with or without spaces", () => {
    expect(() => validateTemplate("x", "Halo {{person.name}} {{ mr.url }}")).not.toThrow();
  });

  it("rejects an unknown placeholder and names it with the template", () => {
    expect(() => validateTemplate("nudge.txt", "Halo {{person.nmae}}")).toThrow(
      /nudge\.txt.*person\.nmae/,
    );
  });

  it("rejects an empty template", () => {
    expect(() => validateTemplate("x", "  \n ")).toThrow(TemplateError);
  });

  it("accepts every built-in template", () => {
    for (const name of TEMPLATE_NAMES) {
      expect(() => validateTemplate(name, DEFAULT_TEMPLATES[name])).not.toThrow();
    }
  });
});

describe("renderTemplate", () => {
  it("replaces every occurrence and trims the result", () => {
    expect(renderTemplate("\nHalo {{person.name}}, {{ person.name }}!\n{{mr.url}}\n", values)).toBe(
      "Halo Alice, Alice!\nhttps://gitlab.example/g/p/-/merge_requests/7",
    );
  });

  it("does not expand placeholders that appear inside a substituted value", () => {
    const tricky = { ...values, "mr.title": "{{owner.name}}" };
    expect(renderTemplate("{{mr.title}}", tricky)).toBe("{{owner.name}}");
  });

  it("refuses an unknown placeholder at render time too", () => {
    expect(() => renderTemplate("{{nope}}", values)).toThrow(TemplateError);
  });
});

describe("escapeMarkdown and markdownLink", () => {
  it("escapes what Markdown would turn into formatting, and nothing else", () => {
    expect(escapeMarkdown("[ESS-28] feat(x): a_b *c* `d` <e> ~f~ #1 | \\")).toBe(
      "\\[ESS-28\\] feat(x): a\\_b \\*c\\* \\`d\\` \\<e\\> \\~f\\~ \\#1 \\| \\\\",
    );
  });

  it("links the escaped title to the URL, encoding characters that would end the link", () => {
    expect(markdownLink("[ESS-28] feat(x)", "https://gitlab.example/g/p/-/merge_requests/7")).toBe(
      "[\\[ESS-28\\] feat(x)](https://gitlab.example/g/p/-/merge_requests/7)",
    );
    expect(markdownLink("t", "https://x.example/a (b)<c>")).toBe(
      "[t](https://x.example/a%20%28b%29%3Cc%3E)",
    );
  });

  it("gives every built-in template the clickable MR link", () => {
    for (const name of TEMPLATE_NAMES) expect(DEFAULT_TEMPLATES[name]).toContain("{{mr.link}}");
  });
});

describe("describeFindings", () => {
  it("says there are none, or the total with each severity in order", () => {
    expect(describeFindings([])).toBe("tidak ada findings");
    expect(
      describeFindings([
        { severity: "Minor", count: 7 },
        { severity: "Nit", count: 1 },
      ]),
    ).toBe("ada 8 findings (7 Minor, 1 Nit)");
  });

  it("names findings without a severity, and leaves out the brackets when none has one", () => {
    expect(
      describeFindings([
        { severity: "Major", count: 1 },
        { severity: "", count: 2 },
      ]),
    ).toBe("ada 3 findings (1 Major, 2 tanpa severity)");
    expect(describeFindings([{ severity: "", count: 1 }])).toBe("ada 1 finding");
  });

  it("escapes a severity name that Markdown would format", () => {
    expect(describeFindings([{ severity: "Nit_pick", count: 1 }])).toBe(
      "ada 1 finding (1 Nit\\_pick)",
    );
  });
});

describe("describeFindings for an Agent Re-review", () => {
  it("counts only the new findings", () => {
    expect(describeFindings([], true)).toBe("tidak ada findings baru");
    expect(describeFindings([{ severity: "Minor", count: 1 }], true)).toBe(
      "ada 1 finding baru (1 Minor)",
    );
    expect(
      describeFindings(
        [
          { severity: "Major", count: 1 },
          { severity: "Minor", count: 1 },
        ],
        true,
      ),
    ).toBe("ada 2 findings baru (1 Major, 1 Minor)");
    expect(describeFindings([{ severity: "", count: 1 }], true)).toBe("ada 1 finding baru");
  });
});

describe("the built-in re-review findings notice", () => {
  it("tells the Author what the Agent Re-review found and where to read it", () => {
    expect(DEFAULT_TEMPLATES["notice.refindings"]).toBe(
      "Halo {{person.name}}, saya sudah review ulang update MR kamu: {{review.findings}}.\n{{mr.link}}\nDetailnya ada di komentar MR.",
    );
    const text = renderTemplate(DEFAULT_TEMPLATES["notice.refindings"], {
      ...values,
      "review.findings": "ada 2 findings baru (1 Major, 1 Minor)",
    });
    expect(text).toBe(
      "Halo Alice, saya sudah review ulang update MR kamu: ada 2 findings baru (1 Major, 1 Minor).\n[Add thing](https://gitlab.example/g/p/-/merge_requests/7)\nDetailnya ada di komentar MR.",
    );
  });
});

describe("the built-in findings notice", () => {
  it("tells the Author what the Agent Review found and where to read it", () => {
    const text = renderTemplate(DEFAULT_TEMPLATES["notice.findings"], {
      ...values,
      "review.findings": "ada 8 findings (7 Minor, 1 Nit)",
    });
    expect(text).toBe(
      "Halo Alice, saya sudah review MR kamu: ada 8 findings (7 Minor, 1 Nit).\n[Add thing](https://gitlab.example/g/p/-/merge_requests/7)\nDetailnya ada di komentar MR.",
    );
  });
});

describe("loadTemplates", () => {
  it("uses the built-in Indonesian defaults when the folder does not exist", () => {
    expect(loadTemplates(join(tempDir(), "missing"))).toEqual(DEFAULT_TEMPLATES);
    expect(DEFAULT_TEMPLATES.nudge).toContain("boleh minta tolong review");
  });

  it("has a built-in Indonesian re-review template that asks for another look", () => {
    expect(TEMPLATE_NAMES).toContain("rereview");
    expect(DEFAULT_TEMPLATES.rereview).toBe(
      "Halo {{person.name}}, MR ini sudah saya update sesuai review-mu. Boleh minta tolong dicek lagi?\n{{mr.link}}\nTerima kasih!",
    );
    expect(renderTemplate(DEFAULT_TEMPLATES.rereview, { ...values, "person.name": "Bob" })).toBe(
      "Halo Bob, MR ini sudah saya update sesuai review-mu. Boleh minta tolong dicek lagi?\n[Add thing](https://gitlab.example/g/p/-/merge_requests/7)\nTerima kasih!",
    );
  });

  it("lets rereview.txt replace the re-review template", () => {
    const directory = tempDir();
    writeFileSync(join(directory, "rereview.txt"), "Cek lagi {{person.name}}: {{mr.url}}");
    const loaded = loadTemplates(directory);
    expect(loaded.rereview).toBe("Cek lagi {{person.name}}: {{mr.url}}");
    expect(loaded.nudge).toBe(DEFAULT_TEMPLATES.nudge);
  });

  it("lets a file replace one template and keeps the others", () => {
    const directory = tempDir();
    writeFileSync(join(directory, "reminder.txt"), "Ping {{person.name}}: {{mr.url}}\n");
    const loaded = loadTemplates(directory);
    expect(loaded.reminder).toBe("Ping {{person.name}}: {{mr.url}}\n");
    expect(loaded.nudge).toBe(DEFAULT_TEMPLATES.nudge);
  });

  it("stops with the file name when a template file has an unknown placeholder", () => {
    const directory = tempDir();
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "nudge.txt"), "Halo {{who}}");
    expect(() => loadTemplates(directory)).toThrow(/nudge\.txt.*who/);
  });
});
