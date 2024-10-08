# Variables
variable "repo_name" {
  type        = string
  description = "Name of the repository"
}

variable "apply_batch_processor_concurrency" {
  type        = bool
  default     = false
  description = "Whether to apply reserved concurrency to the batch processor Lambda"
}


variable "lambda_artifacts_bucket_name" {
  type        = string
  description = "Name of the S3 bucket containing Lambda artifacts"
}

variable "commit_sha" {
  type        = string
  description = "Short SHA of the Git commit"
}

variable "aws_region_tf" {
  type        = string
  default     = "eu-central-1"
  description = "AWS region for resources"
}

variable "partition_processor_concurrency" {
  type        = number
  default     = 10
  description = "Provisioned concurrency for partition processor Lambda"
}

variable "batch_processor_concurrency" {
  type        = number
  default     = 100
  description = "Reserved concurrency for batch processor Lambda"
}

# IAM Role for Lambda functions
resource "aws_iam_role" "lambda_role" {
  name = "lambda_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  tags = merge(local.default_tags, {
    Name = "LambdaExecutionRole"
  })
}

# IAM Policy attachment for Lambda VPC access
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# IAM Policy for Lambda permissions
resource "aws_iam_role_policy" "lambda_permissions" {
  name = "lambda_permissions_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.batch_processor.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:BatchWriteItem"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region_tf}:*:log-group:/aws/lambda/*:*"
      }
    ]
  })
}

# Lambda function: Partition Processor
resource "aws_lambda_function" "partition_processor" {
  function_name = "partitionProcessorLambda"
  s3_bucket     = var.lambda_artifacts_bucket_name
  s3_key        = "${var.repo_name}/partitionProcessorLambda_${var.commit_sha}.zip"
  handler       = "dist/index.handler"
  runtime       = "nodejs18.x"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 300
  memory_size   = 256
  publish       = true # Required for provisioned concurrency
  vpc_config {
    subnet_ids         = [data.aws_subnet.private.id]
    security_group_ids = [data.aws_security_group.allow_internal.id]
  }
  environment {
    variables = {
      BATCH_PROCESSOR_FUNCTION_NAME = aws_lambda_function.batch_processor.function_name
      AWS_REGION_TF                 = var.aws_region_tf
    }
  }
  tags = merge(local.default_tags, {
    Name = "PartitionProcessorLambda"
  })
}

# Lambda function: Batch Processor
resource "aws_lambda_function" "batch_processor" {
  function_name                  = "batchProcessorLambda"
  s3_bucket                      = var.lambda_artifacts_bucket_name
  s3_key                         = "${var.repo_name}/batchProcessorLambda_${var.commit_sha}.zip"
  handler                        = "dist/index.handler"
  runtime                        = "nodejs18.x"
  role                           = aws_iam_role.lambda_role.arn
  timeout                        = 300
  memory_size                    = 256
  reserved_concurrent_executions = var.apply_batch_processor_concurrency ? var.batch_processor_concurrency : null
  vpc_config {
    subnet_ids         = [data.aws_subnet.private.id]
    security_group_ids = [data.aws_security_group.allow_internal.id]
  }
  tags = merge(local.default_tags, {
    Name = "BatchProcessorLambda"
  })
}

# Step Functions State Machine
resource "aws_sfn_state_machine" "contest_processor" {
  name     = "ContestProcessor"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    "Comment" : "Process contest participants for partitions 0 and 1",
    "StartAt" : "InitializePartitions",
    "States" : {
      "FinalizeProcessing" : {
        "End" : true,
        "Result" : {
          "status" : "completed"
        },
        "Type" : "Pass"
      },
      "InitializePartitions" : {
        "Next" : "ProcessPartitions",
        "Result" : {
          "partitions" : [
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9
          ]
        },
        "Type" : "Pass"
      },
      "ProcessPartitions" : {
        "ItemsPath" : "$.partitions",
        "Iterator" : {
          "StartAt" : "InvokeLambda",
          "States" : {
            "InvokeLambda" : {
              "End" : true,
              "Parameters" : {
                "FunctionName" : "arn:aws:lambda:eu-central-1:418272774889:function:partitionProcessorLambda",
                "Payload" : {
                  "contestId.$" : "$$.Execution.Input.contestId",
                  "partitionId.$" : "$",
                  "winningSelectionId.$" : "$$.Execution.Input.winningSelectionId"
                }
              },
              "Resource" : "arn:aws:states:::lambda:invoke",
              "Type" : "Task"
            }
          }
        },
        "MaxConcurrency" : 2,
        "Next" : "FinalizeProcessing",
        "Type" : "Map"
      }
    }
  })

  tags = merge(local.default_tags, {
    Name = "ContestProcessorStateMachine"
  })
}

# IAM Role for Step Functions
resource "aws_iam_role" "step_functions_role" {
  name = "step_functions_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })
  tags = merge(local.default_tags, {
    Name = "StepFunctionsExecutionRole"
  })
}

# IAM Policy for Step Functions to invoke Lambda
resource "aws_iam_role_policy" "step_functions_lambda_invoke" {
  name = "step_functions_lambda_invoke_policy"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.partition_processor.arn,
          aws_lambda_function.batch_processor.arn
        ]
      }
    ]
  })
}