from contextlib import redirect_stdout
import base64
import hashlib
import hmac
import importlib.util
import io
import json
import os
from pathlib import Path
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

SCRIPTS = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result
candidate = module('candidate', 'test-candidate.py')
guard = module('guard', 'guard-academy-plan.py')
smoke = module('smoke', 'check-serverless-endpoint.py')
SECRET = 'mock-jwt-secret-at-least-32-characters'


def jwt(**overrides):
    claims = {'sub': 'test-user', 'aud': ['workshop-service'], 'iss': 'workshop-auth', 'exp': time.time()+120}
    claims.update(overrides)
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    body = encode({'alg': 'HS256'}) + '.' + encode(claims)
    signature = hmac.new(SECRET.encode(), body.encode(), hashlib.sha256).digest()
    return body + '.' + base64.urlsafe_b64encode(signature).decode().rstrip('=')


def plan(address, kind, actions, mode='fresh', version=''):
    return {'variables': {'deployment_mode': {'value': mode}, 'auth_version_override': {'value': version}},
            'resource_changes': [{'address': address, 'type': kind, 'mode': 'managed', 'change': {'actions': actions}}]}


class CandidateTest(unittest.TestCase):
    def test_valid_signature_claims_and_selected_version(self):
        response = {'statusCode': 200, 'body': json.dumps({'accessToken': jwt(), 'tokenType': 'Bearer'})}
        self.assertTrue(candidate.verify_invocation({'StatusCode': 200, 'ExecutedVersion': '7'}, response, '7', SECRET))

    def test_wrong_version_function_error_and_unauthorized_identity_fail(self):
        response = {'statusCode': 200, 'body': json.dumps({'accessToken': jwt(), 'tokenType': 'Bearer'})}
        for metadata in ({'StatusCode': 200, 'ExecutedVersion': '8'},
                         {'StatusCode': 200, 'ExecutedVersion': '7', 'FunctionError': 'Unhandled'},
                         {'StatusCode': 202, 'ExecutedVersion': '7'}):
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                candidate.verify_invocation(metadata, response, '7', SECRET)
        with self.assertRaises(ValueError):
            candidate.verify_invocation({'StatusCode': 200, 'ExecutedVersion': '7'}, {'statusCode': 401}, '7', SECRET)

    def test_expired_foreign_or_tampered_jwt_fails(self):
        for value in (jwt(exp=0), jwt(iss='other'), jwt(aud='other'), jwt()+'.extra'):
            with self.assertRaises(ValueError):
                candidate.verify_token(value, SECRET)
        with self.assertRaises(ValueError):
            candidate.verify_token(jwt(), SECRET+'different')

    def test_configuration_mismatch_does_not_echo_credentials(self):
        values = {'IDENTITY_URL': 'http://private.example:8081', 'AUTH_SERVICE_TOKEN': 'private-auth', 'JWT_SECRET': SECRET}
        candidate.verify_configuration({'Environment': {'Variables': values}}, values['IDENTITY_URL'], 'private-auth', SECRET)
        for name in values:
            changed = dict(values, **{name: 'different-private-value'})
            with self.assertRaises(ValueError) as caught:
                candidate.verify_configuration({'Environment': {'Variables': changed}}, values['IDENTITY_URL'], 'private-auth', SECRET)
            self.assertNotIn('private-auth', str(caught.exception))
            self.assertNotIn(SECRET, str(caught.exception))


class GuardTest(unittest.TestCase):
    def test_fresh_base_create_and_readonly_role_are_allowed(self):
        self.assertTrue(guard.validate(plan('aws_lambda_function.auth', 'aws_lambda_function', ['create'])))
        data = plan('data.aws_iam_role.lab', 'aws_iam_role', ['read'])
        data['resource_changes'][0]['mode'] = 'data'
        self.assertTrue(guard.validate(data))

    def test_untested_public_bootstrap_and_legacy_fallback_are_blocked(self):
        for address, kind in [('aws_lambda_alias.prod[0]', 'aws_lambda_alias'),
                              ('aws_apigatewayv2_route.auth[0]', 'aws_apigatewayv2_route'),
                              ('aws_apigatewayv2_route.fase4["ANY /api/v1/clientes"]', 'aws_apigatewayv2_route'),
                              ('aws_apigatewayv2_integration.service[0]', 'aws_apigatewayv2_integration')]:
            with self.subTest(address=address), self.assertRaises(ValueError):
                guard.validate(plan(address, kind, ['create']))

    def test_selected_candidate_is_allowed_but_iam_db_and_replace_are_not(self):
        self.assertTrue(guard.validate(plan('aws_lambda_alias.prod[0]', 'aws_lambda_alias', ['create'], version='7')))
        for address, kind, actions in [('aws_iam_role.new', 'aws_iam_role', ['create']),
                                       ('aws_db_instance.postgres', 'aws_db_instance', ['update']),
                                       ('aws_lambda_function.auth', 'aws_lambda_function', ['delete', 'create'])]:
            with self.assertRaises(ValueError):
                guard.validate(plan(address, kind, actions, version='7'))

    def test_legacy_noop_move_and_restricted_route_rollback_are_preserved(self):
        self.assertTrue(guard.validate(plan('aws_lambda_alias.prod[0]', 'aws_lambda_alias', ['no-op'], mode='legacy')))
        rollback = plan('aws_apigatewayv2_route.fase4["ANY /api/v1/clientes"]', 'aws_apigatewayv2_route', ['delete'], mode='legacy')
        with self.assertRaises(ValueError):
            guard.validate(rollback)
        self.assertTrue(guard.validate(rollback, True))
        with self.assertRaises(ValueError):
            guard.validate(plan('aws_apigatewayv2_route.auth[0]', 'aws_apigatewayv2_route', ['delete'], mode='legacy'), True)


class PostCheckTest(unittest.TestCase):
    def test_bootstrap_reports_candidate_without_calling_public_api(self):
        values = {'api_gateway_url': 'https://new.example/prod', 'auth_candidate_version': '7', 'auth_public_active': False}
        with patch.object(smoke, 'output', side_effect=lambda name: values[name]), \
                patch.object(smoke, 'urlopen') as request, redirect_stdout(io.StringIO()), \
                patch.dict(os.environ, {}, clear=True):
            smoke.main()
        request.assert_not_called()

    def test_active_smoke_uses_actual_output_not_stale_github_variable(self):
        values = {'api_gateway_url': 'https://new.example/prod', 'auth_candidate_version': '8', 'auth_public_active': True}
        error = HTTPError('https://new.example', 422, 'invalid cpf', {}, None)
        with patch.object(smoke, 'output', side_effect=lambda name: values[name]), \
                patch.object(smoke, 'urlopen', side_effect=error) as request, \
                patch.dict(os.environ, {'API_GATEWAY_URL': 'https://old.example/prod'}, clear=True), \
                redirect_stdout(io.StringIO()):
            smoke.main()
        self.assertEqual('https://new.example/prod/api/auth/cpf', request.call_args.args[0].full_url)


if __name__ == '__main__':
    unittest.main()
