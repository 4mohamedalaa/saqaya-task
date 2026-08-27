output "input_queue_url" {
  value = aws_sqs_queue.logs.url
}

output "dead_letter_queue_url" {
  value = aws_sqs_queue.dead_letter.url
}

output "archive_bucket_name" {
  value = aws_s3_bucket.logs.id
}
