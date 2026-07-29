// compat-sh is a /bin/sh that is deliberately not a shell.
//
// A distroless image has no shell, which is the point. But an existing
// Kubernetes deployment may still name one, most commonly in a lifecycle hook:
//
//	lifecycle:
//	  preStop:
//	    exec:
//	      command: ["/bin/sh", "-c", "sleep 10"]
//
// The kubelet execs that literally. With no /bin/sh the hook fails on every pod
// termination. The usual fixes are both bad: put busybox in the image and hand
// an attacker a full toolbox, or edit the chart and give up being a drop-in.
//
// This is the third option. It answers to /bin/sh and implements exactly the
// vocabulary a lifecycle hook needs, and it CANNOT execute anything. There is no
// fork, no exec, no PATH lookup, no shell grammar. An attacker who reaches it
// can wait. That makes the image strictly safer than one carrying a real shell
// while still satisfying the interface the old infra asserts.
//
// Anything outside the allowed vocabulary is refused, loudly, and nothing runs.
// Refusing is correct: silently succeeding would let a hook that expects real
// work believe it happened.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	exitOK      = 0
	exitRefused = 2
)

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

func run(args []string, errOut *os.File) int {
	if len(args) == 0 {
		// An interactive shell is the one thing this must never pretend to be.
		fmt.Fprintln(errOut, "compat-sh: no interactive shell; this is a lifecycle-hook shim, not /bin/sh")
		return exitRefused
	}
	if args[0] != "-c" {
		fmt.Fprintf(errOut, "compat-sh: only -c is supported, got %q\n", args[0])
		return exitRefused
	}
	if len(args) < 2 {
		fmt.Fprintln(errOut, "compat-sh: -c requires a script argument")
		return exitRefused
	}
	return runScript(args[1], errOut)
}

// runScript accepts a semicolon or newline separated list of allowed commands.
// Every command must be recognised; one unrecognised command refuses the whole
// script rather than running the prefix, because a partially executed hook is
// worse than a refused one.
func runScript(script string, errOut *os.File) int {
	stmts := splitStatements(script)
	if len(stmts) == 0 {
		return exitOK
	}

	// Validate everything BEFORE running anything.
	type action struct{ sleep time.Duration }
	actions := make([]action, 0, len(stmts))
	for _, stmt := range stmts {
		fields := strings.Fields(stmt)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "true", ":":
			if len(fields) != 1 {
				fmt.Fprintf(errOut, "compat-sh: %q takes no arguments\n", fields[0])
				return exitRefused
			}
			actions = append(actions, action{})
		case "sleep":
			if len(fields) != 2 {
				fmt.Fprintln(errOut, "compat-sh: sleep takes exactly one argument")
				return exitRefused
			}
			d, err := parseSleep(fields[1])
			if err != nil {
				fmt.Fprintf(errOut, "compat-sh: %v\n", err)
				return exitRefused
			}
			actions = append(actions, action{sleep: d})
		default:
			fmt.Fprintf(errOut, "compat-sh: refusing %q; the allowed vocabulary is sleep, true\n", fields[0])
			return exitRefused
		}
	}

	for _, a := range actions {
		if a.sleep > 0 {
			time.Sleep(a.sleep)
		}
	}
	return exitOK
}

func splitStatements(script string) []string {
	raw := strings.FieldsFunc(script, func(r rune) bool {
		return r == ';' || r == '\n'
	})
	out := make([]string, 0, len(raw))
	for _, s := range raw {
		if t := strings.TrimSpace(s); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// parseSleep accepts a bare number of seconds, which is what a lifecycle hook
// writes. A suffixed duration is accepted too since it costs nothing. An upper
// bound exists because a hook that sleeps longer than any plausible
// terminationGracePeriod is a mistake, not an intent.
func parseSleep(arg string) (time.Duration, error) {
	const maxSleep = 10 * time.Minute

	if secs, err := strconv.ParseFloat(arg, 64); err == nil {
		if secs < 0 {
			return 0, fmt.Errorf("sleep %q is negative", arg)
		}
		d := time.Duration(secs * float64(time.Second))
		if d > maxSleep {
			return 0, fmt.Errorf("sleep %q exceeds the %s ceiling", arg, maxSleep)
		}
		return d, nil
	}

	d, err := time.ParseDuration(arg)
	if err != nil {
		return 0, fmt.Errorf("sleep %q is not a number of seconds or a duration", arg)
	}
	if d < 0 {
		return 0, fmt.Errorf("sleep %q is negative", arg)
	}
	if d > maxSleep {
		return 0, fmt.Errorf("sleep %q exceeds the %s ceiling", arg, maxSleep)
	}
	return d, nil
}
