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
