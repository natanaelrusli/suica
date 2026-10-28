import { readFileSync } from "node:fs";

/** The one version: package.json, which sits next to `src/` in the repo and in the installed copy. */
export const VERSION: string = (
  JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as {
    version: string;
  }
).version;
