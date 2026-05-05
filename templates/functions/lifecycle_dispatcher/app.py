"""Translate ASG lifecycle SNS events into a lifecycle Step Function execution.

Subscribed to the ``alternat-lifecycle`` SNS topic. The ASG publishes a JSON
payload like::

    {
      "LifecycleHookName": "alternat-eu-west-1a-terminating",
      "AutoScalingGroupName": "alternat-eu-west-1a-...",
      "EC2InstanceId": "i-...",
      "LifecycleTransition": "autoscaling:EC2_INSTANCE_TERMINATING",
      "Origin": "AutoScalingGroup",
      "Destination": "EC2"
    }

The dispatcher resolves the per-AZ failover record from the ``ASG_MAP_JSON``
env-var (keyed by ASG name) and starts the lifecycle Step Function with the
matching input. **Zero AWS API calls except StartExecution** — keeps the IAM
surface tight and removes a hidden dependency on autoscaling endpoints.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

_sfn = boto3.client("stepfunctions")

LIFECYCLE_SM_ARN = os.environ["LIFECYCLE_STATE_MACHINE_ARN"]
ASG_MAP: dict[str, dict[str, Any]] = json.loads(os.environ.get("ASG_MAP_JSON", "{}"))
OBSERVATION_MODE = os.environ.get("OBSERVATION_MODE", "false").lower() == "true"


def handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    LOG.info("dispatcher event: %s", json.dumps(event))

    if OBSERVATION_MODE:
        LOG.info("OBSERVATION_MODE=true — not starting any lifecycle SFN executions")
        return {"started": [], "skipped_reason": "observation_mode"}

    started = []
    for record in event.get("Records", []):
        try:
            payload = json.loads(record["Sns"]["Message"])
        except Exception:
            LOG.exception("could not parse SNS message: %s", record)
            continue

        asg_name = payload.get("AutoScalingGroupName")
        if not asg_name:
            LOG.warning("SNS message has no AutoScalingGroupName: %s", payload)
            continue

        az_record = ASG_MAP.get(asg_name)
        if not az_record:
            LOG.warning("no ASG_MAP entry for %s — skipping (deployed AZ list: %s)",
                        asg_name, list(ASG_MAP.keys()))
            continue

        sfn_input = {
            "az": az_record["az"],
            "asg_name": asg_name,
            "instance_id": payload.get("EC2InstanceId"),
            "route_table_ids": az_record["route_table_ids"],
            "fallback_kind": az_record["fallback_kind"],
            "fallback_target_id": az_record["fallback_target_id"],
        }
        result = _sfn.start_execution(
            stateMachineArn=LIFECYCLE_SM_ARN,
            name=f"lifecycle-{az_record['az']}-{int(time.time() * 1000)}",
            input=json.dumps(sfn_input),
        )
        LOG.info("started %s", result["executionArn"])
        started.append(result["executionArn"])

    return {"started": started}
