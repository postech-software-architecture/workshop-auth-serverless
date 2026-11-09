"""Reject destructive or out-of-bound changes before a serverless apply."""
import argparse,json
from pathlib import Path

def validate(plan, allow_phase4_route_removal=False):
    allowed={'aws_security_group','aws_cloudwatch_log_group','aws_lambda_function','aws_lambda_alias','aws_lambda_permission','aws_apigatewayv2_api','aws_apigatewayv2_vpc_link','aws_apigatewayv2_integration','aws_apigatewayv2_route','aws_apigatewayv2_stage'}
    for change in plan.get('resource_changes',[]):
        if change.get('mode','managed')!='managed':continue
        actions=change['change']['actions']
        address=change['address']
        route_rollback=allow_phase4_route_removal and actions==['delete'] and (address.startswith('aws_apigatewayv2_route.fase4[') or address=='aws_apigatewayv2_integration.fase4[0]')
        if (any(action in actions for action in ['delete','forget']) and not route_rollback) or change['type'] not in allowed:
            raise ValueError('Academy boundary rejects '+change['address']+' ('+','.join(actions)+')')
    return True

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('plan',type=Path);p.add_argument('--allow-phase4-route-removal',action='store_true');a=p.parse_args()
    validate(json.loads(a.plan.read_text(encoding='utf-8')),a.allow_phase4_route_removal);print('Academy plan boundary passed; no IAM/EKS/RDS or destructive legacy changes')
if __name__=='__main__':main()
