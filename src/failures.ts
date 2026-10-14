import type { Notification } from "./format.ts";
import type { GitlabFailureKind } from "./gitlab.ts";

export type FailureKind = GitlabFailureKind | "notifier";

export interface FailureTracker {
  /** Records a failure; true when this kind was not already failing (tell the Owner once). */
  fail(kind: FailureKind): boolean;
  /** Clears a failure; true when it was failing. */
  recover(kind: FailureKind): boolean;
}

export function createFailureTracker(): FailureTracker {
  const active = new Set<FailureKind>();
  return {
    fail(kind) {
      const isNew = !active.has(kind);
      active.add(kind);
      return isNew;
    },
    recover: (kind) => active.delete(kind),
  };
}

export function failureNotification(kind: GitlabFailureKind, hostname: string): Notification {
  switch (kind) {
    case "glab-missing":
      return {
        title: "glab tidak ditemukan",
        body: "Pasang glab atau perbaiki PATH-nya supaya polling GitLab jalan lagi.",
      };
    case "gitlab-auth":
      return {
        title: "Login GitLab gagal",
        body: `Jalankan: glab auth login --hostname ${hostname}`,
      };
    case "gitlab-unreachable":
      return {
        title: "GitLab tidak terjangkau",
        body: "Akan dicoba lagi otomatis dengan jeda yang makin panjang.",
      };
    case "gitlab-error":
      return {
        title: "GitLab mengembalikan error",
        body: "Lihat log MR Review Assistant untuk detailnya.",
      };
  }
}
