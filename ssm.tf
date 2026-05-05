resource "aws_ssm_document" "verify" {
  count = var.enable_nat_restore_ssm_check ? 1 : 0

  name            = "${var.name_prefix}-verify"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "alternat — verify NAT instance health before route restore"
    parameters    = {}
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "verify"
        inputs = {
          timeoutSeconds = "20"
          runCommand = [
            "set -euo pipefail",
            "[ \"$(sysctl -n net.ipv4.ip_forward)\" = \"1\" ] || { echo 'ip_forward not enabled'; exit 1; }",
            "iptables -t nat -L POSTROUTING -n | grep -q MASQUERADE || { echo 'MASQUERADE rule missing'; exit 1; }",
            "TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')",
            "PUBLIC_IP=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/public-ipv4 || true)",
            "[ -n \"$PUBLIC_IP\" ] || { echo 'no public IPv4 (EIP not claimed)'; exit 1; }",
            "curl -s -o /dev/null --max-time 5 -w 'http_code=%%{http_code}\\n' https://www.amazon.com || { echo 'egress curl failed'; exit 1; }",
            "echo 'alternat verify OK; public_ip='\"$PUBLIC_IP\"",
          ]
        }
      }
    ]
  })

  tags = local.common_tags
}
