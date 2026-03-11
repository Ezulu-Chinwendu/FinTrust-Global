# terraform/outputs.tf

output "api_endpoint" {
  description = "Base URL for the FinTrust API"
  value       = aws_apigatewayv2_stage.prod.invoke_url
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function"
  value       = aws_lambda_function.api.function_name
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB payments table"
  value       = aws_dynamodb_table.payments.name
}

output "vpc_id" {
  description = "ID of the deployed VPC"
  value       = aws_vpc.main.id
}

