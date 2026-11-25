/** Machine-written files (protobuf output, lockfiles, build output, snapshots, mocks, golden contracts). */
const GENERATED_PATH = new RegExp(
  [
    String.raw`\.pb$`,
    String.raw`\.pb\.(go|cc|h|dart)$`,
    String.raw`_grpc\.pb\.go$`,
    String.raw`\.pb\.gw\.go$`,
    String.raw`\.pbjson\.dart$`,
    String.raw`_pb2(_grpc)?\.py$`,
    String.raw`_pb\.(js|d\.ts)$`,
    String.raw`(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|go\.sum|Cargo\.lock|Podfile\.lock|Package\.resolved|poetry\.lock|uv\.lock)$`,
    String.raw`\.min\.(js|css)$`,
    String.raw`\.map$`,
    String.raw`(^|/)(dist|build)/`,
    String.raw`(^|/)__snapshots__/`,
    String.raw`\.snap$`,
    String.raw`(^|/)mock_[^/]*\.go$`,
    String.raw`_mock\.go$`,
    String.raw`(^|/)contracts/[^/]+\.v1\.json$`,
  ].join("|"),
);
// shortcut: header sniff covers only the first 500 diff chars, widen if a generator buries its marker.
const GENERATED_HEADER = /Code generated|DO NOT EDIT/;
/** True for a file nobody reviews by hand; `diff` is the raw text, when GitLab sent it. */
export const isGeneratedFile = (path: string, diff: string | null | undefined): boolean =>
  GENERATED_PATH.test(path) || (diff != null && GENERATED_HEADER.test(diff.slice(0, 500)));
