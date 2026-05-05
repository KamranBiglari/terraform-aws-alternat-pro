"""Connectivity probe Lambda for the alternat module.

This Lambda has **no AWS API dependencies**. It runs in the private subnet so
its HTTPS curl exits through the NAT instance under test, but it does not
call boto3 at all — every piece of AWS state it needs (route tables, live
NAT instance ENI, lock state) is gathered by the Step Function in the
service plane and passed in as input. This eliminates the need for any
VPC endpoints in the customer VPC: when NAT is broken, the probe's
``urllib`` calls fail (which is the signal we want) and the SFN handles
the route flip from the service plane where AWS APIs are always reachable.

Event shape::

    {
      "az": "eu-west-1a",
      "test_urls": ["https://aws.amazon.com", "https://www.google.com"],
      "timeout_seconds": 5,
      "live_eni_id": "eni-aaaaaaaa" | null,
      "route_tables": [<DescribeRouteTables[].RouteTables entries>],
      "expected_fallback_kind": "transit_gateway",
      "expected_fallback_target_id": "tgw-...",
      "lock": { "cooldown_until": 1700000000, "last_target": "ec2" },
      "cooldown_seconds": 300
    }

Return shape::

    {
      "az": "eu-west-1a",
      "healthy": true,
      "current_target": "ec2" | "fallback" | "stale" | "unknown" | "mixed",
      "ec2_eni_id": "eni-aaaaaaaa",
      "now_epoch": 1700000000,
      "new_cooldown_until": 1700000300,
      "cooldown_active": false,
      "details": {
        "url_results": {...},
        "per_rt_classification": {"rtb-aaa": "ec2", ...},
        "expected_fallback_kind": "...",
        "expected_fallback_target_id": "..."
      }
    }
"""

from __future__ import annotations

import json
import logging
import os
import socket
import ssl
import time
import urllib.error
import urllib.request
from typing import Any

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def _curl(url: str, timeout: float) -> dict[str, Any]:
    try:
        ctx = ssl.create_default_context()
        with urllib.request.urlopen(url, timeout=timeout, context=ctx) as resp:
            return {"ok": 200 <= resp.status < 400, "status": resp.status}
    except urllib.error.HTTPError as e:
        return {"ok": False, "status": e.code, "error": str(e)}
    except (urllib.error.URLError, socket.timeout, TimeoutError) as e:
        return {"ok": False, "status": None, "error": str(e)}
    except Exception as e:  # pragma: no cover - defensive catch-all
        return {"ok": False, "status": None, "error": f"{type(e).__name__}: {e}"}


def _default_route_target(rt: dict[str, Any]) -> dict[str, str]:
    """Return the target of the 0.0.0.0/0 route in a route table dict, or {}."""
    for r in rt.get("Routes", []):
        if r.get("DestinationCidrBlock") == "0.0.0.0/0":
            if r.get("NetworkInterfaceId"):
                return {"network_interface_id": r["NetworkInterfaceId"]}
            if r.get("NatGatewayId"):
                return {"nat_gateway_id": r["NatGatewayId"]}
            if r.get("TransitGatewayId"):
                return {"transit_gateway_id": r["TransitGatewayId"]}
            if r.get("GatewayId"):
                return {"gateway_id": r["GatewayId"]}
    return {}


def _classify_rt(target: dict[str, str], live_eni: str | None,
                 fallback_kind: str | None, fallback_id: str | None) -> str:
    if not target:
        return "unknown"

    eni = target.get("network_interface_id")
    ngw = target.get("nat_gateway_id")
    tgw = target.get("transit_gateway_id")

    if fallback_kind in ("nat_gateway", "existing_nat_gateway") and ngw and ngw == fallback_id:
        return "fallback"
    if fallback_kind == "transit_gateway" and tgw and tgw == fallback_id:
        return "fallback"
    if fallback_kind == "network_interface" and eni and eni == fallback_id:
        return "fallback"

    if eni:
        if live_eni and eni == live_eni:
            return "ec2"
        return "stale"

    return "unknown"


def _consensus(values: list[str]) -> str:
    unique = set(values)
    if not unique:
        return "unknown"
    if len(unique) == 1:
        return next(iter(unique))
    return "mixed"


def handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:  # noqa: D401
    LOG.info("probe event: %s", json.dumps(event, default=str))

    az = event["az"]
    test_urls = event.get("test_urls", []) or []
    timeout = float(event.get("timeout_seconds", 5))
    live_eni_id = event.get("live_eni_id")
    route_tables = event.get("route_tables", []) or []
    expected_fallback_kind = event.get("expected_fallback_kind")
    expected_fallback_target_id = event.get("expected_fallback_target_id")
    lock = event.get("lock") or {}
    cooldown_seconds = int(event.get("cooldown_seconds", 0))

    now_epoch = int(time.time())
    cooldown_until = int(lock.get("cooldown_until", 0))
    cooldown_active = now_epoch < cooldown_until

    url_results = {url: _curl(url, timeout) for url in test_urls}
    healthy = bool(url_results) and any(v["ok"] for v in url_results.values())

    per_rt: dict[str, str] = {}
    for rt in route_tables:
        rt_id = rt.get("RouteTableId", "unknown")
        target = _default_route_target(rt)
        per_rt[rt_id] = _classify_rt(target, live_eni_id, expected_fallback_kind, expected_fallback_target_id)
    current_target = _consensus(list(per_rt.values()))

    response = {
        "az": az,
        "healthy": healthy,
        "current_target": current_target,
        "ec2_eni_id": live_eni_id,
        "now_epoch": now_epoch,
        "new_cooldown_until": now_epoch + cooldown_seconds,
        "cooldown_active": cooldown_active,
        "last_target": lock.get("last_target"),
        "details": {
            "url_results": url_results,
            "per_rt_classification": per_rt,
            "expected_fallback_kind": expected_fallback_kind,
            "expected_fallback_target_id": expected_fallback_target_id,
        },
    }
    LOG.info("probe result: %s", json.dumps(response))
    return response
