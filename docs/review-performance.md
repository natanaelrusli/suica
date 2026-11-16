# Review performance measurement

Use a local fixture harness with a fake model runner that injects the same fixed latency on every run. Do not send requests to GitLab or a model service.

Run 20 sequential fixture reviews, then one batch at the configured review concurrency. Capture concurrency, fixture diff and description sizes, `queue_wait_ms`, per-stage duration distributions (input, checkout, model, judge, posting, cleanup), and event-loop delay. Report median and p95 for durations. Keep fixture data and fake latency identical between runs. Record measured numbers only after executing the procedure; no measurements are claimed here. If checkout dominates, evaluate repository caching as a separate change.
