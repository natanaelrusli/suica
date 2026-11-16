export type ReviewStage = "input" | "checkout" | "model" | "judge" | "posting" | "cleanup";
export type ReviewStageRecord = {
  reviewId: number;
  stage: ReviewStage;
  durationMs: number;
  outcome: "ok" | "failed";
};

export async function measureReviewStage<T>(
  id: number,
  stage: ReviewStage,
  now: () => number,
  emit: (record: ReviewStageRecord) => void,
  run: () => Promise<T>,
): Promise<T> {
  const started = now();
  let outcome: ReviewStageRecord["outcome"] = "ok";
  try {
    return await run();
  } catch (error) {
    outcome = "failed";
    throw error;
  } finally {
    emit({ reviewId: id, stage, durationMs: Math.max(0, now() - started), outcome });
  }
}
