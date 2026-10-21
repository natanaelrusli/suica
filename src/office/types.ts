/** The document `suica office --json` prints. The app window decodes it; see contracts/office.v1.json. */
export type OfficeStatus = "working" | "waiting" | "idle" | "exited";

export interface RecentAction {
  /** Epoch milliseconds. */
  readonly at: number;
  readonly text: string;
}

/** What an adapter knows about one Session. */
export interface RawSession {
  /** claude, codex, gemini, or the name of a generic adapter. */
  readonly agent: string;
  readonly sessionId: string;
  readonly cwd: string;
  readonly status: OfficeStatus;
  /** One line naming the current action and its target, never conversation text. */
  readonly activity: string;
  /** Oldest first, at most 5. */
  readonly recentActions: readonly RecentAction[];
  readonly startedAt: number | null;
  /** Epoch milliseconds of the Session's last sign of life. */
  readonly updatedAt: number;
  readonly pid: number | null;
}

export interface OfficeSession extends RawSession {
  /** The Room: the git repository root, or the folder itself outside a repository. */
  readonly room: string;
  readonly roomName: string;
  /** The `.app` that hosts the Session (a terminal, the Claude app), when it can be found. */
  readonly hostApp: string | null;
}

export interface OfficeJson {
  readonly version: 1;
  /** Epoch milliseconds. */
  readonly generatedAt: number;
  readonly sessions: readonly OfficeSession[];
}

export interface ProcInfo {
  readonly pid: number;
  readonly ppid: number;
  /** The whole command line. */
  readonly command: string;
}

/** What detection needs from the machine; tests pass a fake. */
export interface Probe {
  readonly home: string;
  readonly now: number;
  pidAlive(pid: number): boolean;
  processes(): readonly ProcInfo[];
  /** The working folder of a process, or null when it cannot be read. */
  cwdOf(pid: number): string | null;
}

export type Adapter = (probe: Probe) => readonly RawSession[];

/** Active in the last minute is working; a Session written to in the last 3 minutes is live. */
export const IDLE_AFTER_MS = 60_000;
export const LIVE_WINDOW_MS = 180_000;
/** The CLI reports a Session whose process exited for this long; the app keeps the same stay. */
export const EXITED_STAY_MS = 300_000;
