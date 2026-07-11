# Test TLS fixtures

`localhost.crt` / `localhost.key` are a self-signed certificate + key for
`CN=localhost` (SAN: `DNS:localhost`, `IP:127.0.0.1`), valid for 10 years.

They are **intentionally committed** so the HTTPS/WSS integration and e2e tests
can bind real TLS listeners on `127.0.0.1:0` without any network or CA access.
They are throwaway test material and are never used outside the test suite.

Regenerate with:

```sh
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout localhost.key -out localhost.crt \
  -days 3650 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```
