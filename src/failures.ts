import type { Notification } from "./format.ts";
import type { GitlabFailureKind } from "./gitlab.ts";

export type TeamsFailureReportKind = "teams-unavailable" | "teams-error";
export type FailureKind = GitlabFailureKind | "notifier" | "state" | TeamsFailureReportKind;

export interface FailureTracker {
  /** Records a failure and returns how many polls in a row have now failed with this kind. */
  fail(kind: FailureKind): number;
  /** Clears a failure; true when it was failing. */
  recover(kind: FailureKind): boolean;
}

export function createFailureTracker(): FailureTracker {
  const streaks = new Map<FailureKind, number>();
  return {
    fail(kind) {
      const streak = (streaks.get(kind) ?? 0) + 1;
      streaks.set(kind, streak);
      return streak;
    },
    recover: (kind) => streaks.delete(kind),
  };
}

/**
 * How many consecutive failures of a kind before the Owner is told. A network that is not up yet
 * right after the Mac wakes is normal, so "unreachable" kinds need a second failure to be believed.
 */
export const NOTIFY_AFTER: Readonly<Record<FailureKind, number>> = {
  "glab-missing": 1,
  "gitlab-auth": 1,
  "gitlab-unreachable": 2,
  "gitlab-error": 1,
  notifier: 1,
  state: 1,
  "teams-unavailable": 2,
  "teams-error": 1,
};

export const STATE_FAILURE_NOTIFICATION: Notification = {
  title: "Penyimpanan state bermasalah",
  body: "MR Review Assistant tidak bisa menyimpan state. Alert bisa terulang; lihat log untuk detailnya.",
};

export function teamsFailureNotification(kind: TeamsFailureReportKind): Notification {
  return kind === "teams-unavailable"
    ? {
        title: "Teams tidak terhubung",
        body: "Pesan Teams menunggu dan akan dicoba lagi; pesan yang sudah gagal terkirim tidak diulang.",
      }
    : {
        title: "Teams mengembalikan error",
        body: "Jika login kedaluwarsa, jalankan ulang sh scripts/login.sh di repo teams-mcp-login.",
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
