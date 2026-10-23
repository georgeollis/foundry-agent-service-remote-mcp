import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch

import azure.functions as func
from openapi_schema_validator import OAS30Validator
from openapi_spec_validator import validate

SOURCE = Path(__file__).resolve().parents[1] / "src" / "pet-insurance-api"
module_spec = importlib.util.spec_from_file_location("insurance_api", SOURCE / "function_app.py")
api = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(api)
SPEC = json.loads((SOURCE / "openapi.json").read_text())


class OpenApiTests(unittest.TestCase):
    def invoke(self, name, method="GET", *, route=None, query=None, body=None, content_type="application/json"):
        request = func.HttpRequest(
            method=method, url="http://localhost:7071/api/test",
            route_params=route or {}, params=query or {},
            headers={"content-type": content_type}, body=body or b"",
        )
        result = getattr(api, name)(request)
        return result.status_code, json.loads(result.get_body())

    def assert_schema(self, payload, schema):
        OAS30Validator(SPEC["components"]["schemas"][schema]).validate(payload)

    def test_spec_matches_registered_business_routes(self):
        validate(SPEC)
        functions = api.app.get_functions()
        business = [f for f in functions if f.get_function_name() != "get_openapi"]
        declared = {
            (path.lstrip("/"), method.upper(), operation["operationId"])
            for path, methods in SPEC["paths"].items() for method, operation in methods.items()
        }
        registered = set()
        for function in business:
            binding = function.get_bindings_dict()["bindings"][0]
            for method in binding["methods"]:
                registered.add((binding["route"], method.value, function.get_function_name()))
        self.assertEqual(registered, declared)

    def test_coverage_active_lapsed_and_errors(self):
        for number, covered in [("POLICY-001", True), ("POLICY-002", False)]:
            with self.subTest(policy=number):
                status, payload = self.invoke("get_policy_coverage", route={"policy_number": number})
                self.assertEqual(status, 200)
                self.assertEqual(payload["covered"], covered)
                self.assert_schema(payload, "Coverage")
        status, payload = self.invoke("get_policy_coverage", route={"policy_number": "missing"})
        self.assertEqual(status, 404)
        self.assert_schema(payload, "Error")
        status, payload = self.invoke(
            "get_policy_coverage", route={"policy_number": "POLICY-001"}, query={"service_type": "invalid"}
        )
        self.assertEqual(status, 400)
        self.assert_schema(payload, "Error")

    def test_claim_lookup(self):
        for number, expected in [("CLAIM-001", 200), ("missing", 404)]:
            status, payload = self.invoke("get_claim_status", route={"claim_number": number})
            self.assertEqual(status, expected)
            self.assert_schema(payload, "Claim" if expected == 200 else "Error")

    def test_preauthorization_outcomes(self):
        for number, cost, expected, amount in [
            ("POLICY-001", 100, "approved", 80),
            ("POLICY-001", 3000, "manual_review", 0),
            ("POLICY-002", 100, "manual_review", 0),
        ]:
            with self.subTest(policy=number, cost=cost):
                body = {"policy_number": number, "service_type": "wellness", "estimated_cost": cost}
                self.assert_schema(body, "PreauthorizationRequest")
                status, payload = self.invoke("request_preauthorization", "POST", body=json.dumps(body).encode())
                self.assertEqual(status, 200)
                self.assertEqual(payload["status"], expected)
                self.assertEqual(payload["approved_amount"], amount)
                self.assert_schema(payload, "Preauthorization")

    def test_preauthorization_rejects_invalid_payloads(self):
        valid = {"policy_number": "POLICY-001", "service_type": "wellness", "estimated_cost": 100}
        invalid = [
            b"not json", b"null", b"[]", b"{}",
            *[json.dumps({**valid, "estimated_cost": value}).encode() for value in [0, -1, True, "100", None, float("nan"), float("inf")]],
            json.dumps({**valid, "service_type": "invalid"}).encode(),
            json.dumps({**valid, "extra": "unexpected"}).encode(),
        ]
        for body in invalid:
            with self.subTest(body=body):
                status, payload = self.invoke("request_preauthorization", "POST", body=body)
                self.assertEqual(status, 400)
                self.assert_schema(payload, "Error")
        status, payload = self.invoke(
            "request_preauthorization", "POST", body=json.dumps(valid).encode(), content_type="text/plain"
        )
        self.assertEqual(status, 415)
        self.assert_schema(payload, "Error")
        status, payload = self.invoke(
            "request_preauthorization", "POST", body=json.dumps({**valid, "policy_number": "missing"}).encode()
        )
        self.assertEqual(status, 404)
        self.assert_schema(payload, "Error")

    def test_served_spec_uses_deployed_host_not_request_host(self):
        with patch.dict(os.environ, {"WEBSITE_HOSTNAME": "demo.azurewebsites.net"}):
            status, payload = self.invoke("get_openapi")
        self.assertEqual(status, 200)
        self.assertEqual(payload["servers"], [{"url": "https://demo.azurewebsites.net/api"}])
        validate(payload)
        self.assertEqual(json.loads((SOURCE / "openapi.json").read_text()), SPEC)


if __name__ == "__main__":
    unittest.main()
