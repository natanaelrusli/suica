/** Frozen remote write unit persisted by Store; payload is the exact JSON sent. */
export interface PostPart {
  key: string;
  kind: "inline" | "summary";
  endpoint: string;
  payload: string;
  state: "pending" | "sending" | "confirmed" | "uncertain" | "rejected";
  remoteId: string | null;
}

/** Fencing token and expiration for one review posting owner. */
export interface PostingLease {
  reviewId: number;
  token: string;
  expiresAt: number;
}
