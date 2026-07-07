// smoke — the MINIMAL-PRODUCTION-IMAGE conformance fixture.
//
// A stdlib-only HTTP server (no external modules ⇒ vendorHash = null). It is
// built through the SAME minimal builder the fleet ships production Go
// services with, packaged into a scratch-base image, then RUN by the
// serve-test: the test curls /health and asserts 200 — proving the stripped
// image (no shell, no libc, no init) actually starts and serves, with no
// missing dependency at runtime.
//
// It also exercises the exact stdlib surfaces the static Go build tags target:
//   - time.LoadLocation  → zoneinfo (timetzdata)
//   - net + os/user      → the pure-Go resolvers (netgo/osusergo)
// If those tags were missing, a scratch image would fail these at runtime.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/user"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		// Touch the surfaces the static tags cover — if the tags were
		// absent, a scratch (no /etc, no tzdata) image would error here.
		_, _ = time.LoadLocation("UTC")
		_, _ = user.Current()
		_, _ = net.LookupHost("localhost")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	addr := ":" + port
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	// Signal readiness on stdout so the serve-test can wait deterministically.
	fmt.Println("smoke-listening", addr)
	log.Fatal(http.Serve(ln, nil))
}
