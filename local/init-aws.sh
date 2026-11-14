#!/bin/sh
set -e
E="--endpoint-url=http://floci:4566"
for q in os-eventos billing-comandos execution-comandos; do
  aws $E sqs create-queue --queue-name "$q-dlq" >/dev/null
  dlq_arn="arn:aws:sqs:us-east-1:000000000000:$q-dlq"
  aws $E sqs create-queue --queue-name "$q" --attributes "{\"VisibilityTimeout\":\"30\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$dlq_arn\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"}" >/dev/null
  echo "fila $q ok"
done
aws $E dynamodb describe-table --table-name oficina-execucoes >/dev/null 2>&1 || aws $E dynamodb create-table \
  --table-name oficina-execucoes \
  --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S AttributeName=gsi1pk,AttributeType=S AttributeName=gsi1sk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --global-secondary-indexes 'IndexName=gsi1,KeySchema=[{AttributeName=gsi1pk,KeyType=HASH},{AttributeName=gsi1sk,KeyType=RANGE}],Projection={ProjectionType=ALL}' >/dev/null
echo "tabela oficina-execucoes ok"
