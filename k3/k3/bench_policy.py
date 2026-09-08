#!/usr/bin/env python3
"""Measure the per-tick inference cost of the duck's policies on this board.

Mirrors what duck-control/src/policy.rs does: Level3 graph optimisation, one intra-op
thread, a single [1,61] observation in and [1,14] out. Run with `--providers` to show
what the runtime actually offers.
"""
import argparse, glob, os, statistics, sys, time

import numpy as np
import onnxruntime as ort


def build(path):
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    so.intra_op_num_threads = 1          # policy.rs: INTRA_THREADS = 1
    so.inter_op_num_threads = 1
    return ort.InferenceSession(path, sess_options=so, providers=["CPUExecutionProvider"])


def bench(sess, warmup=200, iters=2000):
    inp = sess.get_inputs()[0]
    x = np.zeros((1, 61), dtype=np.float32)
    feed = {inp.name: x}
    for _ in range(warmup):
        sess.run(None, feed)
    samples = np.empty(iters, dtype=np.float64)
    for i in range(iters):
        t0 = time.perf_counter_ns()
        sess.run(None, feed)
        samples[i] = (time.perf_counter_ns() - t0) / 1e6   # ms
    return samples


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="/opt/robot/policies/current")
    ap.add_argument("--iters", type=int, default=2000)
    ap.add_argument("--providers", action="store_true")
    args = ap.parse_args()

    print(f"onnxruntime {ort.__version__}  providers={ort.get_available_providers()}")
    if args.providers:
        return

    paths = sorted(glob.glob(os.path.join(args.dir, "*.onnx")))
    if not paths:
        sys.exit(f"no .onnx under {args.dir}")

    print(f"{'policy':<24} {'mean':>7} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>7}  {'budget':>7}")
    print("-" * 76)
    for p in paths:
        s = bench(build(p), iters=args.iters)
        mean, p50, p95, p99, mx = (statistics.mean(s), np.percentile(s, 50),
                                   np.percentile(s, 95), np.percentile(s, 99), s.max())
        budget = 1000.0 / 50.0          # one 50 Hz tick
        print(f"{os.path.basename(p):<24} {mean:7.3f} {p50:7.3f} {p95:7.3f} "
              f"{p99:7.3f} {mx:7.3f}  {mean/budget*100:6.2f}%")


if __name__ == "__main__":
    main()
