storage "file" {
  path = "/tmp/vault-data"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/tmp/cert.pem"
  tls_key_file = "/tmp/key.pem"
}


disable_mlock = "true"
