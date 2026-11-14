"""Validate a numbered Lambda candidate without modifying aliases or routes."""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def aws_json(arguments):
    result = subprocess.run(['aws', *arguments], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def verify_token(token, secret):
    parts = token.split('.')
    if len(parts) != 3:
        raise ValueError('Invalid JWT structure')
    def decode(value):
        return base64.urlsafe_b64decode(value + '=' * ((-len(value)) % 4))
    header, claims = json.loads(decode(parts[0])), json.loads(decode(parts[1]))
    signature = hmac.new(secret.strip().encode(), (parts[0] + '.' + parts[1]).encode(), hashlib.sha256).digest()
    if header.get('alg') != 'HS256' or not hmac.compare_digest(signature, decode(parts[2])):
        raise ValueError('Candidate JWT signature mismatch')
    audience = claims.get('aud')
    valid_audience = audience == 'workshop-service' or isinstance(audience, list) and 'workshop-service' in audience
    if claims.get('iss') != 'workshop-auth' or not valid_audience or not claims.get('sub') or claims.get('exp', 0) <= time.time():
        raise ValueError('Candidate JWT claims mismatch')
    return True


def verify_configuration(configuration, identity_url, auth_token, jwt_secret):
    values = configuration.get('Environment', {}).get('Variables', {})
    expected = {'IDENTITY_URL': identity_url, 'AUTH_SERVICE_TOKEN': auth_token, 'JWT_SECRET': jwt_secret}
    if any(not hmac.compare_digest(str(values.get(name, '')).encode(), value.encode())
           for name, value in expected.items()):
        raise ValueError('Candidate identity URL or runtime credentials do not match this deployment')


def verify_invocation(metadata, response, version, jwt_secret):
    if metadata.get('FunctionError') or metadata.get('StatusCode') != 200 or str(metadata.get('ExecutedVersion')) != version:
        raise ValueError('Invocation did not execute the selected immutable candidate successfully')
    if response.get('statusCode') != 200:
        raise ValueError('Candidate did not authenticate the eligible test identity')
    body = json.loads(response['body'])
    if body.get('tokenType') != 'Bearer':
        raise ValueError('Candidate did not return a Bearer token')
    return verify_token(body['accessToken'], jwt_secret)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--function', required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    if not re.fullmatch('[1-9][0-9]*', args.version):
        parser.error('Use a numbered immutable candidate, never prod or $LATEST')
    required = ('TEST_CPF', 'JWT_SECRET', 'AUTH_SERVICE_TOKEN')
    if any(not os.environ.get(name) for name in required):
        parser.error('Configure private TEST_CPF, JWT_SECRET and AUTH_SERVICE_TOKEN')
    nlb_name = os.environ.get('FASE4_NLB_NAME') or 'workshop-fase4-internal'
    load_balancer = aws_json(['elbv2', 'describe-load-balancers', '--names', nlb_name])['LoadBalancers'][0]
    if load_balancer['Scheme'] != 'internal':
        raise ValueError('Candidate identity NLB must be internal')
    discovered_url = 'http://' + load_balancer['DNSName'] + ':8081'
    if os.environ.get('IDENTITY_URL') and os.environ['IDENTITY_URL'] != discovered_url:
        raise ValueError('Identity override does not match the discovered private NLB')
    configuration = aws_json(['lambda', 'get-function-configuration', '--function-name', args.function,
                              '--qualifier', args.version])
    verify_configuration(configuration, discovered_url, os.environ['AUTH_SERVICE_TOKEN'], os.environ['JWT_SECRET'])
    with tempfile.TemporaryDirectory() as directory:
        request, response = Path(directory) / 'request.json', Path(directory) / 'response.json'
        request.write_text(json.dumps({'version': '2.0', 'body': json.dumps({'cpf': os.environ['TEST_CPF']}),
                                       'isBase64Encoded': False}), encoding='utf-8')
        metadata = aws_json(['lambda', 'invoke', '--function-name', args.function, '--qualifier', args.version,
                             '--cli-binary-format', 'raw-in-base64-out', '--payload', 'fileb://' + request.as_posix(), str(response)])
        verify_invocation(metadata, json.loads(response.read_text(encoding='utf-8')), args.version, os.environ['JWT_SECRET'])
    print('Candidate configuration, private HTTP identity and JWT verified. No alias/route changed; no CPF/token printed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        print('Candidate validation failed. Check its private configuration and eligible test identity; values suppressed.', file=sys.stderr)
        sys.exit(1)
