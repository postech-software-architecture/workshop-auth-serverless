output "api_gateway_url" {
  description = "Public URL of the prod API Gateway stage."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/${aws_apigatewayv2_stage.prod.name}"
}

output "lambda_function_name" {
  value = aws_lambda_function.auth.function_name
}

output "vpc_link_id" {
  value = aws_apigatewayv2_vpc_link.this.id
}


output "auth_candidate_version" {
  description = "New immutable version to test before selecting it in AUTH_VERSION_OVERRIDE; prod is preserved by default."
  value       = aws_lambda_function.auth.version
}

output "identity_url" {
  description = "Private identity listener discovered from the Phase4 NLB; not a public endpoint."
  value       = local.identity_url
}

output "auth_public_active" {
  value = local.auth_active
}

output "phase4_routes_active" {
  value = local.routes_active
}

output "auth_active_version" {
  value = try(aws_lambda_alias.prod[0].function_version, "")
}
