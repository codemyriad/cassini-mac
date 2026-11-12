# Owned profiling sampler shutdown

PR #248 CI run 43125910172, job 130893380920 failed while waiting for its owned `/usr/bin/top` child after SIGTERM. The sampler already writes directly to a file. Cleanup now kills and reaps that diagnostic child; probe results and measurement gates are unchanged.

Three real child-process cases cover an ignored SIGTERM, a cooperative SIGTERM handler and an already exited sampler. The committed production mutation replaces kill with terminate. Its cooperative child exits zero and fails the required SIGKILL exit-code assertion immediately, rather than failing a hang timeout. Restored tests pass.

Replay from the repository root with `SAMPLER_EVIDENCE=/absolute/path/outside/repo python3 evidence/mac/flaky/sampler-stop/replay.py`. The output directory must be outside the checkout.
