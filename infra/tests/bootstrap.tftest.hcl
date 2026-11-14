# All AWS calls and the remote state are mocked. No real infrastructure is created.
mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/LabRole" }
  }
  mock_data "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/net/workshop-fase4-internal/1234567890123456"
      dns_name = "internal-workshop-fase4.example.elb.amazonaws.com"
      internal = true
      vpc_id   = "vpc-00000000000000001"
    }
  }
  mock_data "aws_lb_listener" {
    defaults = {
      arn  = "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener/net/workshop-fase4-internal/1234567890123456/1234567890123456"
      port = 80
    }
  }
  mock_data "aws_lambda_alias" {
    defaults = { function_version = "5" }
  }
  mock_data "aws_lambda_function" {
    defaults = {
      environment = [{ variables = {
        IDENTITY_URL       = "http://internal-workshop-fase4.example.elb.amazonaws.com:8081"
        AUTH_SERVICE_TOKEN = "mock-auth-token-at-least-32-characters"
        JWT_SECRET         = "mock-jwt-secret-at-least-32-characters"
      } }]
    }
  }
}

override_data {
  target = data.terraform_remote_state.cluster
  values = {
    outputs = {
      vpc_id             = "vpc-00000000000000001"
      vpc_cidr           = "10.0.0.0/16"
      private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    }
  }
}
override_data {
  target = data.aws_lb_listener.identity
  values = { port = 8081 }
}

variables {
  cluster_state_bucket = "mock-state-bucket"
  deployment_mode      = "fresh"
  jwt_secret           = "mock-jwt-secret-at-least-32-characters"
  auth_service_token   = "mock-auth-token-at-least-32-characters"
  adot_layer_arn       = "arn:aws:lambda:us-east-1:111111111111:layer:mock-adot:1"
  new_relic_api_key    = "mock-new-relic-at-least-20-characters"
  service_version      = "abcdef0"
  lambda_artifact_path = "tests/function-fixture.txt"
}

run "fresh_bootstrap_without_alias_or_legacy_nlb" {
  command = plan
  variables { fase4_routes_enabled = true }
  assert {
    condition     = length(data.aws_lambda_alias.current) == 0 && length(data.aws_lb.internal_api) == 0
    error_message = "Fresh installation must not read a previous alias or legacy NLB."
  }
  assert {
    condition     = length(aws_lambda_alias.prod) == 0 && length(aws_apigatewayv2_route.auth) == 0 && length(aws_lambda_permission.gateway) == 0 && length(aws_apigatewayv2_route.fase4) == 0
    error_message = "Bootstrap must not activate an untested candidate or public business routes."
  }
  assert {
    condition     = length(aws_apigatewayv2_integration.service) == 0 && length(aws_apigatewayv2_route.service) == 0
    error_message = "Fresh installation must not create a legacy fallback."
  }
  assert {
    condition     = aws_lambda_function.auth.role == "arn:aws:iam::111111111111:role/LabRole" && aws_lambda_function.auth.environment[0].variables["IDENTITY_URL"] == "http://internal-workshop-fase4.example.elb.amazonaws.com:8081"
    error_message = "Lambda must retain LabRole and discover the private Phase4 identity listener."
  }
}

run "fresh_activation_selects_numbered_candidate" {
  command = plan
  variables {
    auth_version_override = "7"
    fase4_routes_enabled  = true
  }
  assert {
    condition     = aws_lambda_alias.prod[0].function_version == "7" && length(aws_apigatewayv2_route.auth) == 1 && length(aws_lambda_permission.gateway) == 1
    error_message = "Activation must select the requested immutable version."
  }
  assert {
    condition     = length(aws_apigatewayv2_route.fase4) > 0 && length(aws_apigatewayv2_route.service) == 0
    error_message = "Fresh public routing must use only Phase4 routes."
  }
}

run "legacy_update_preserves_existing_alias_and_fallback" {
  command = plan
  variables { deployment_mode = "legacy" }
  assert {
    condition     = aws_lambda_alias.prod[0].function_version == "5" && length(aws_apigatewayv2_route.service) == 1 && length(aws_apigatewayv2_integration.service) == 1
    error_message = "Legacy updates must preserve the old alias and default integration."
  }
}

run "reject_identity_override_outside_private_nlb" {
  command = plan
  variables { identity_url = "http://other.example:8081" }
  expect_failures = [aws_lambda_function.auth]
}

run "reject_candidate_with_different_credentials" {
  command = plan
  variables {
    auth_version_override = "7"
    auth_service_token    = "different-auth-token-at-least-32-characters"
  }
  expect_failures = [aws_lambda_alias.prod]
}
