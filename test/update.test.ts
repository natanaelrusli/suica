import { generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import { checkForUpdate, isNewer, verifyManifest } from "../src/update.ts";

const PREFIX = "https://github.com/natanaelrusli/suica/releases/download/";

function keys() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { pem: publicKey.export({ type: "spki", format: "pem" }).toString(), privateKey };
}

const { pem, privateKey } = keys();

function signed(over: Record<string, string> = {}) {
  const text = JSON.stringify({
    version: "0.2.0",
    arch: "arm64",
    url: `${PREFIX}v0.2.0/suica.tar.gz`,
    sha256: "a".repeat(64),
    ...over,
  });
  return { text, sig: sign(null, Buffer.from(text), privateKey).toString("base64") };
}

function fakeFetch(
  routes: (url: string) => Response | Promise<Response>,
  seen: string[] = [],
): typeof fetch {
  return (input: string | URL | Request) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    seen.push(url);
    return Promise.resolve(routes(url));
  };
}

function serve(text: string, sig: string) {
  return (url: string) => (url.endsWith(".sig") ? new Response(sig) : new Response(text));
}

describe("isNewer", () => {
  it("compares numerically", () => {
    expect(isNewer("0.1.10", "0.1.9")).toBe(true);
    expect(isNewer("0.1.0", "0.1.0")).toBe(false);
    expect(isNewer("0.0.9", "0.1.0")).toBe(false);
  });
});

describe("verifyManifest", () => {
  it("accepts a good pair", () => {
    const { text, sig } = signed();
    expect(verifyManifest(text, sig, pem).version).toBe("0.2.0");
  });

  it("rejects a flipped byte in the manifest", () => {
    const { text, sig } = signed();
    expect(() => verifyManifest(text.replace("0.2.0", "0.2.1"), sig, pem)).toThrow();
  });

  it("rejects a signature from another key", () => {
    const { text, sig } = signed();
    expect(() => verifyManifest(text, sig, keys().pem)).toThrow();
  });

  it("rejects bad JSON even when signed", () => {
    const text = "not json";
    const sig = sign(null, Buffer.from(text), privateKey).toString("base64");
    expect(() => verifyManifest(text, sig, pem)).toThrow();
  });

  it("rejects a url on another host", () => {
    const { text, sig } = signed({ url: "https://evil.example/suica.tar.gz" });
    expect(() => verifyManifest(text, sig, pem)).toThrow(/url/);
  });

  it("honors a custom allowed prefix", () => {
    const base = "http://127.0.0.1:9/download/";
    const { text, sig } = signed({ url: `${base}v0.2.0/x.tar.gz` });
    expect(verifyManifest(text, sig, pem, base).version).toBe("0.2.0");
    expect(() => verifyManifest(text, sig, pem)).toThrow(/url/);
  });
});

describe("checkForUpdate", () => {
  const base = { current: "0.1.0", arch: "arm64", publicKeyPem: pem };

  it("reports an available update from the default release URLs", async () => {
    const { text, sig } = signed();
    const seen: string[] = [];
    const r = await checkForUpdate({ ...base, fetch: fakeFetch(serve(text, sig), seen) });
    expect(r).toEqual({ status: "available", current: "0.1.0", latest: "0.2.0" });
    expect(seen).toEqual([
      "https://github.com/natanaelrusli/suica/releases/latest/download/latest.json",
      "https://github.com/natanaelrusli/suica/releases/latest/download/latest.json.sig",
    ]);
  });

  it("is up to date when equal or newer locally", async () => {
    const { text, sig } = signed();
    const f = fakeFetch(serve(text, sig));
    expect(await checkForUpdate({ ...base, current: "0.2.0", fetch: f })).toEqual({
      status: "up-to-date",
      current: "0.2.0",
    });
    expect((await checkForUpdate({ ...base, current: "0.3.0", fetch: f })).status).toBe(
      "up-to-date",
    );
  });

  it("is unavailable on a 404", async () => {
    const r = await checkForUpdate({
      ...base,
      fetch: fakeFetch(() => new Response("no", { status: 404 })),
    });
    expect(r.status).toBe("unavailable");
  });

  it("is unavailable when fetch rejects", async () => {
    const r = await checkForUpdate({
      ...base,
      fetch: fakeFetch(() => Promise.reject(new Error("offline"))),
    });
    expect(r.status).toBe("unavailable");
  });

  it("is unavailable for another architecture", async () => {
    const { text, sig } = signed();
    const r = await checkForUpdate({ ...base, arch: "x64", fetch: fakeFetch(serve(text, sig)) });
    expect(r.status).toBe("unavailable");
  });

  it("honors a custom baseUrl for fetching and for the url prefix", async () => {
    const baseUrl = "http://127.0.0.1:9/releases";
    const { text, sig } = signed({ url: `${baseUrl}/download/v0.2.0/x.tar.gz` });
    const seen: string[] = [];
    const r = await checkForUpdate({ ...base, baseUrl, fetch: fakeFetch(serve(text, sig), seen) });
    expect(r.status).toBe("available");
    expect(seen[0]).toBe(`${baseUrl}/latest/download/latest.json`);
    const d = await checkForUpdate({ ...base, fetch: fakeFetch(serve(text, sig)) });
    expect(d.status).toBe("unavailable");
  });
});
