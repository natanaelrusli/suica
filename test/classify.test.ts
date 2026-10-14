import { describe, expect, it } from "vitest";
import { classifyFailure } from "../src/gitlab.ts";

describe("classifyFailure", () => {
  it("recognises an HTTP 401 but not a number that merely contains 401", () => {
    expect(classifyFailure({ code: 1, stderr: "HTTP 401 Unauthorized" })).toBe("gitlab-auth");
    expect(classifyFailure({ code: 1, stderr: "listening on port 14012" })).toBe("gitlab-error");
    expect(classifyFailure({ code: 1, stderr: "request id 4010" })).toBe("gitlab-error");
  });

  it("recognises an unauthorised response written without the number", () => {
    expect(classifyFailure({ code: 1, stderr: "401: Unauthorized" })).toBe("gitlab-auth");
    expect(classifyFailure({ code: 1, stderr: "you are not logged in" })).toBe("gitlab-auth");
  });
});
