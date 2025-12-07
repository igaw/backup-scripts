#!/usr/bin/env python3
import argparse
import json
import ssl
import sys
import websocket


def ws_connect(host):
    sslopt = {"cert_reqs": ssl.CERT_NONE}
    return websocket.create_connection(f"wss://{host}/api/current", sslopt=sslopt)


def ws_call(ws, method, params=None, req_id=1):
    msg = {
        "jsonrpc": "2.0",
        "id": req_id,
        "msg": "method",
        "method": method,
        "params": params or [],
    }
    ws.send(json.dumps(msg))
    resp = ws.recv()
    return json.loads(resp)


def login(ws, token):
    login = ws_call(ws, "auth.login_with_api_key", [token], req_id=1)
    if "error" in login:
        print("Login failed:", login["error"])
        sys.exit(1)


def create_snapshot(ws, dataset, snapname):
    print(f"Creating snapshot: {snapname}")
    resp = ws_call(
        ws,
        "pool.snapshot.create",
        [{"dataset": dataset, "name": snapname, "recursive": True}],
        req_id=2,
    )

    if "error" in resp:
        print("ERROR:", resp["error"])
        sys.exit(1)

    print("OK:", resp.get("result")["id"])


def prune_snapshots(ws, dataset, keep, prefix):
    print(f"Pruning snapshots, keeping last {keep} with prefix '{prefix}'")

    params = [[["dataset", "=", dataset]], {"order_by": ["name"]}]

    resp = ws_call(ws, "pool.snapshot.query", params, req_id=3)
    snapshots = resp.get("result", [])

    filtered = []
    for snap in snapshots:
        full = snap["name"]
        shortname = full.split("@")[1]
        if shortname.startswith(prefix):
            created = int(snap["properties"]["creation"]["rawvalue"])
            filtered.append((created, shortname, snap["id"]))

    filtered.sort(key=lambda x: x[0], reverse=True)

    to_delete = filtered[keep:]

    req_id = 10
    for created, shortname, snap_id in to_delete:
        print(f"Deleting: {shortname}")
        ws_call(ws, "pool.snapshot.delete", [snap_id], req_id=req_id)
        req_id += 1

    print("Prune completed.")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Create and optionally prune TrueNAS ZFS snapshots over WebSocket."  # noqa: E501
    )

    parser.add_argument(
        "snapname", help="Snapshot name to create (e.g. backup-2025-11-23_12-01)"
    )

    parser.add_argument(
        "--dataset",
    )

    parser.add_argument(
        "--host",
    )

    parser.add_argument(
        "--token",
    )

    parser.add_argument(
        "--prune",
        type=int,
        metavar="N",
        help="Keep only the last N snapshots with the same prefix (default prefix=backup-)",  # noqa: E501
    )

    parser.add_argument(
        "--prefix",
        default="backup-",
        help="Prefix used to match snapshots for pruning (default: backup-)",  # noqa: E501
    )

    return parser.parse_args()


def main():
    args = parse_args()

    ws = ws_connect(args.host)

    login(ws, args.token)

    create_snapshot(ws, args.dataset, args.snapname)

    if args.prune:
        prune_snapshots(ws, args.dataset, args.prune, args.prefix)


if __name__ == "__main__":
    main()
