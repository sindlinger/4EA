#!/usr/bin/env python3
import json
import signal
import socket
import struct
import sys

import numpy as np

try:
    import cupy as cp
    XP = cp
    GPU = True
except Exception:
    XP = np
    GPU = False

RUNNING = True
SERVER = None


def log(msg):
    print(msg, flush=True)


def handle_sigint(_signum, _frame):
    global RUNNING, SERVER
    RUNNING = False
    log("GPU SSA server shutting down (SIGINT)")
    if SERVER is not None:
        try:
            SERVER.close()
        except Exception:
            pass


signal.signal(signal.SIGINT, handle_sigint)


def recv_exact(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def recv_message(sock):
    header = recv_exact(sock, 4)
    if header is None:
        return None
    (length,) = struct.unpack("<I", header)
    if length == 0:
        return ""
    payload = recv_exact(sock, length)
    if payload is None:
        return None
    return payload.decode("utf-8")


def send_message(sock, obj):
    raw = json.dumps(obj).encode("utf-8")
    header = struct.pack("<I", len(raw))
    sock.sendall(header + raw)


def diagonal_averaging(xk, w, k):
    n = w + k - 1
    out = np.zeros(n, dtype=np.float64)
    counts = np.zeros(n, dtype=np.float64)
    for i in range(w):
        for j in range(k):
            out[i + j] += xk[i, j]
            counts[i + j] += 1.0
    out /= counts
    return out


def ssa_trend_and_u(x, window, topk):
    x = XP.asarray(x, dtype=XP.float64)
    n = int(x.shape[0])
    w = max(2, min(int(window), n))
    k = n - w + 1
    if k < 1:
        x_cpu = XP.asnumpy(x) if GPU else x
        return np.asarray(x_cpu), None, w, k

    traj = XP.empty((w, k), dtype=XP.float64)
    for j in range(k):
        traj[:, j] = x[j : j + w]

    u, s, vh = XP.linalg.svd(traj, full_matrices=False)
    r = min(int(topk), int(s.shape[0]))
    if r < 1:
        r = 1

    xk = (u[:, :r] * s[:r]) @ vh[:r, :]
    xk_cpu = XP.asnumpy(xk) if GPU else xk
    trend = diagonal_averaging(xk_cpu, w, k)

    u_cpu = XP.asnumpy(u) if GPU else u
    return trend, u_cpu, w, k


def ssa_recurrence_coeffs(u, r):
    if u is None:
        return None
    u_r = u[:, :r]
    pi = u_r[-1, :]
    v2 = float(np.dot(pi, pi))
    if v2 >= 0.999999:
        return None
    rvec = (u_r[:-1, :] @ pi) / (1.0 - v2)
    return np.asarray(rvec, dtype=np.float64)


def ssa_forecast_from_trend(trend, u, r, horizon):
    rvec = ssa_recurrence_coeffs(u, r)
    if rvec is None:
        return None
    L = u.shape[0]
    y = list(map(float, trend))
    steps = int(horizon)
    for _ in range(steps):
        if len(y) < L - 1:
            break
        last = y[-(L - 1) :]
        next_val = float(np.dot(rvec, last))
        y.append(next_val)
    return y[-steps:]


def linear_forecast(x, horizon, lookback):
    x = np.asarray(x, dtype=np.float64)
    n = x.shape[0]
    lb = max(2, min(int(lookback), n))
    y = x[n - lb :]
    xs = np.arange(lb, dtype=np.float64)
    sum_x = xs.sum()
    sum_y = y.sum()
    sum_xx = (xs * xs).sum()
    sum_xy = (xs * y).sum()
    denom = lb * sum_xx - sum_x * sum_x
    if denom == 0.0:
        slope = 0.0
    else:
        slope = (lb * sum_xy - sum_x * sum_y) / denom
    intercept = (sum_y - slope * sum_x) / lb
    out = []
    for i in range(int(horizon)):
        xh = (lb - 1) + (i + 1)
        out.append(float(intercept + slope * xh))
    return out


def centered_trend_for_repaint(close, window, topk, half, forecast, repaint_bars):
    n = len(close)
    half = max(1, int(half))
    center_len = 2 * half + 1
    out = []
    for bar in range(int(repaint_bars) + 1):
        c = n - 1 - bar
        start = c - half
        if start < 0:
            out.append(float("nan"))
            continue
        seq = []
        ok = True
        for j in range(center_len):
            idx = start + j
            if idx <= n - 1:
                seq.append(close[idx])
            else:
                fidx = idx - (n - 1) - 1
                if fidx < 0 or fidx >= len(forecast):
                    ok = False
                    break
                seq.append(forecast[fidx])
        if not ok:
            out.append(float("nan"))
            continue
        w_eff = min(int(window), center_len)
        r_eff = min(int(topk), w_eff)
        trend, _u, _w, _k = ssa_trend_and_u(seq, w_eff, r_eff)
        if len(trend) <= half:
            out.append(float("nan"))
            continue
        out.append(float(trend[half]))
    return out


def handle_request(req):
    close = req.get("close", [])
    window = int(req.get("window", 64))
    topk = int(req.get("topk", 8))
    half = int(req.get("half", window // 2))
    horizon = int(req.get("horizon", half))
    repaint_bars = int(req.get("repaint_bars", 0))
    lookback = int(req.get("linear_lookback", 32))

    if len(close) < 2:
        return {"ok": False, "err": "close series too short"}

    trend, u, _w, _k = ssa_trend_and_u(close, window, topk)
    r = min(int(topk), int(u.shape[1]) if u is not None else int(topk))

    forecast = ssa_forecast_from_trend(trend, u, r, horizon)
    if forecast is None or len(forecast) < horizon:
        forecast = linear_forecast(trend, horizon, lookback)

    trend_centered = centered_trend_for_repaint(close, window, topk, half, forecast, repaint_bars)
    residual = [float(c - t) for c, t in zip(close, trend[-len(close) :])]

    return {
        "ok": True,
        "gpu": GPU,
        "trend": [float(v) for v in trend[-len(close) :]],
        "trend_centered_series": trend_centered,
        "residual": residual,
        "forecast": [float(v) for v in forecast],
    }


def log_request(req):
    sym = req.get("symbol", "?")
    tf = req.get("timeframe", "?")
    ind = req.get("indicator", "?")
    n = len(req.get("close", []))
    window = req.get("window", "?")
    topk = req.get("topk", "?")
    half = req.get("half", "?")
    horizon = req.get("horizon", "?")
    repaint = req.get("repaint_bars", "?")
    log(f"request: ind={ind} sym={sym} tf={tf} n={n} window={window} topk={topk} half={half} horizon={horizon} repaint={repaint}")


def main(host, port):
    global SERVER
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(5)
    srv.settimeout(1.0)
    SERVER = srv

    log("gpu_ssa_server listening on %s:%d (gpu=%s)" % (host, port, GPU))

    while RUNNING:
        try:
            conn, addr = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break

        log(f"client connected {addr[0]}:{addr[1]}")
        with conn:
            conn.settimeout(2.0)
            while RUNNING:
                try:
                    msg = recv_message(conn)
                except socket.timeout:
                    continue
                except Exception as exc:
                    log("recv error: " + str(exc))
                    break

                if msg is None:
                    log("client disconnected")
                    break

                try:
                    req = json.loads(msg)
                    log_request(req)
                    resp = handle_request(req)
                except Exception as exc:
                    resp = {"ok": False, "err": str(exc)}

                try:
                    send_message(conn, resp)
                except Exception as exc:
                    log("send error: " + str(exc))
                    break

    try:
        srv.close()
    except Exception:
        pass
    log("gpu_ssa_server stopped")


if __name__ == "__main__":
    host = "127.0.0.1"
    port = 7789
    if len(sys.argv) > 1:
        port = int(sys.argv[1])
    main(host, port)
