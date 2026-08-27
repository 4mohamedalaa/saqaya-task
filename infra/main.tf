terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  queue_arn  = aws_sqs_queue.logs.arn
  bucket_arn = aws_s3_bucket.logs.arn
}

resource "aws_kms_key" "logs" {
  description             = "Encrypt log queue and archive data"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.logs.key_id
}

resource "aws_sqs_queue" "dead_letter" {
  name                              = "${var.name}-dlq"
  kms_master_key_id                 = aws_kms_key.logs.arn
  kms_data_key_reuse_period_seconds = 300
  message_retention_seconds         = 1209600
}

resource "aws_sqs_queue" "logs" {
  name                              = "${var.name}-queue"
  kms_master_key_id                 = aws_kms_key.logs.arn
  kms_data_key_reuse_period_seconds = 300
  message_retention_seconds         = 345600
  receive_wait_time_seconds         = 20
  visibility_timeout_seconds        = 180

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.logs.arn]
  })
}

resource "aws_s3_bucket" "logs" {
  bucket_prefix = "${var.name}-${data.aws_caller_identity.current.account_id}-"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.logs.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "archive-and-expire"
    status = "Enabled"

    filter {}

    # Uploads that never completed are invisible but still billed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.log_retention_days
    }

    # The bucket is versioned, so the expiration above only writes a delete
    # marker. These two rules are what actually remove the bytes and make
    # log_retention_days a real retention limit.
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  # Once every version under a key is gone, the leftover delete marker is
  # dead weight that slows listings.
  rule {
    id     = "expire-orphaned-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_security_group" "worker" {
  name_prefix = "${var.name}-"
  description = "Log workers: no inbound traffic"
  vpc_id      = var.vpc_id

  # Prefer VPC endpoints in production and narrow this rule to their SG/prefix lists.
  egress {
    description = "HTTPS to AWS APIs through endpoints or controlled NAT"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "worker" {
  name_prefix = "${var.name}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "worker" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
        Resource = local.queue_arn
      },
      {
        Sid      = "WriteArchive"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${local.bucket_arn}/*"
      },
      {
        Sid      = "UseEncryptionKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.logs.arn
      },
      {
        Sid      = "PublishMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = var.name }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "worker" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.worker.name
}

resource "aws_launch_template" "worker" {
  name_prefix            = "${var.name}-"
  image_id               = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.worker.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.worker.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = true
      kms_key_id  = aws_kms_key.logs.arn
      volume_size = 16
      volume_type = "gp3"
    }
  }

  # In production this bootstraps a pinned, checksummed worker artifact or uses a baked AMI.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf update -y
    dnf install -y amazon-cloudwatch-agent
    echo 'Worker artifact installation belongs in the immutable image pipeline.'
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = var.name
    }
  }
}

resource "aws_autoscaling_group" "worker" {
  name_prefix         = "${var.name}-"
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = var.private_subnet_ids
  health_check_type   = "EC2"

  # GroupInServiceInstances must be published for the backlog-per-instance math.
  default_instance_warmup = 120
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupMaxSize",
    "GroupMinSize",
    "GroupTotalInstances",
  ]

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }

  # The scaling policy owns capacity after creation; without this every apply
  # resets the fleet to var.desired_capacity and drops in-flight work.
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "queue_backlog" {
  name                   = "${var.name}-queue-backlog"
  autoscaling_group_name = aws_autoscaling_group.worker.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = var.target_backlog_per_instance

    # Target tracking needs a metric that falls as capacity rises. Raw queue
    # depth does not, so divide it by the in-service instance count.
    customized_metric_specification {
      metrics {
        id          = "visible"
        label       = "Messages waiting to be processed"
        return_data = false

        metric_stat {
          stat = "Sum"

          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"

            dimensions {
              name  = "QueueName"
              value = aws_sqs_queue.logs.name
            }
          }
        }
      }

      metrics {
        id          = "capacity"
        label       = "Instances currently in service"
        return_data = false

        metric_stat {
          stat = "Average"

          metric {
            namespace   = "AWS/AutoScaling"
            metric_name = "GroupInServiceInstances"

            dimensions {
              name  = "AutoScalingGroupName"
              value = aws_autoscaling_group.worker.name
            }
          }
        }
      }

      metrics {
        id          = "backlog_per_instance"
        label       = "Backlog per instance"
        expression  = "visible / capacity"
        return_data = true
      }
    }
  }
}
