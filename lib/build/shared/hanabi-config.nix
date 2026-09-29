# hanabi-config.nix — the default hanabi.yaml baked into the static-web images.
#
# Shared by lib/build/rust/leptos-build.nix and lib/build/wasm/build.nix, which
# each carried a byte-identical copy. Interpolated at column 0 inside their
# heredocs, so the rendered build script is unchanged.
''
  server:
    static_dir: "/app/static"
    http_port: 80
    health_port: 8080
    request_timeout_secs: 30
    max_concurrent_connections: 10000

  compression:
    enable_gzip: true
    enable_brotli: true

  preflight:
    enabled: false
    critical_files: []
    index_html_path: "index.html"

  cors:
    allowed_origins:
      - "*"
    allowed_methods:
      - "GET"
      - "POST"
      - "OPTIONS"
    allowed_headers:
      - "Content-Type"
      - "Accept"
    expose_headers: []
    max_age_secs: 3600
    allow_credentials: false
''
