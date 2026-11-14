# Preserve existing managed objects when adding conditional first-install paths.
# These are state address migrations, not imports or resource replacements.
moved {
  from = aws_lambda_alias.prod
  to   = aws_lambda_alias.prod[0]
}
moved {
  from = aws_apigatewayv2_integration.auth
  to   = aws_apigatewayv2_integration.auth[0]
}
moved {
  from = aws_apigatewayv2_integration.service
  to   = aws_apigatewayv2_integration.service[0]
}
moved {
  from = aws_apigatewayv2_route.auth
  to   = aws_apigatewayv2_route.auth[0]
}
moved {
  from = aws_apigatewayv2_route.service
  to   = aws_apigatewayv2_route.service[0]
}
moved {
  from = aws_lambda_permission.gateway
  to   = aws_lambda_permission.gateway[0]
}
