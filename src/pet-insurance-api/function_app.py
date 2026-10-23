import json
import logging
import os
import uuid
from pathlib import Path
from typing import Literal

import azure.functions as func
from pydantic import BaseModel, ConfigDict, Field

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

POLICIES = {
    "POLICY-001": {"status": "active", "coverage_percentage": 80, "annual_limit_remaining": 2500.0},
    "POLICY-002": {"status": "lapsed", "coverage_percentage": 0, "annual_limit_remaining": 0.0},
}
SERVICES = {"wellness", "dental", "emergency"}


class PreauthorizationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    policy_number: str = Field(min_length=1, max_length=64)
    service_type: Literal["wellness", "dental", "emergency"]
    estimated_cost: float = Field(gt=0, allow_inf_nan=False)


def response(payload: dict, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload, allow_nan=False), status_code=status_code, mimetype="application/json"
    )


def error(status_code: int, code: str, message: str) -> func.HttpResponse:
    logging.warning("API request rejected: %s", code)
    return response({"code": code, "message": message}, status_code)


@app.route(route="policies/{policy_number}/coverage", methods=["GET"])
def get_policy_coverage(req: func.HttpRequest) -> func.HttpResponse:
    policy_number = req.route_params.get("policy_number")
    policy = POLICIES.get(policy_number)
    if policy is None:
        return error(404, "PolicyNotFound", "Use demo policy POLICY-001 or POLICY-002.")
    service = req.params.get("service_type", "wellness")
    if service not in SERVICES:
        return error(400, "InvalidService", "service_type must be wellness, dental, or emergency.")
    return response({
        "policy_number": policy_number,
        **policy,
        "service_type": service,
        "covered": policy["status"] == "active",
        "currency": "GBP",
        "demo": True,
    })


@app.route(route="claims/{claim_number}", methods=["GET"])
def get_claim_status(req: func.HttpRequest) -> func.HttpResponse:
    if req.route_params.get("claim_number") != "CLAIM-001":
        return error(404, "ClaimNotFound", "Use demo claim CLAIM-001.")
    return response({
        "claim_number": "CLAIM-001",
        "policy_number": "POLICY-001",
        "status": "approved",
        "amount": 125.0,
        "currency": "GBP",
        "demo": True,
    })


@app.route(route="preauthorizations", methods=["POST"])
def request_preauthorization(req: func.HttpRequest) -> func.HttpResponse:
    media_type = req.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if media_type != "application/json":
        return error(415, "UnsupportedMediaType", "Send an application/json request body.")
    try:
        request = PreauthorizationRequest.model_validate(req.get_json())
    except ValueError:
        return error(
            400, "InvalidRequest",
            "Provide policy_number, service_type (wellness, dental, emergency), and a positive numeric estimated_cost; no extra fields.",
        )
    policy = POLICIES.get(request.policy_number)
    if policy is None:
        return error(404, "PolicyNotFound", "Use demo policy POLICY-001 or POLICY-002.")
    approved = policy["status"] == "active" and request.estimated_cost <= policy["annual_limit_remaining"]
    return response({
        "reference": f"PA-{uuid.uuid4().hex[:12].upper()}",
        "policy_number": request.policy_number,
        "service_type": request.service_type,
        "status": "approved" if approved else "manual_review",
        "estimated_cost": request.estimated_cost,
        "approved_amount": round(request.estimated_cost * policy["coverage_percentage"] / 100, 2) if approved else 0.0,
        "currency": "GBP",
        "demo": True,
    })


@app.route(route="openapi.json", methods=["GET"])
def get_openapi(req: func.HttpRequest) -> func.HttpResponse:
    specification = json.loads(Path(__file__).with_name("openapi.json").read_text(encoding="utf-8"))
    hostname = os.environ.get("WEBSITE_HOSTNAME")
    base_url = f"https://{hostname}/api" if hostname else "http://localhost:7071/api"
    specification["servers"] = [{"url": base_url}]
    return response(specification)
