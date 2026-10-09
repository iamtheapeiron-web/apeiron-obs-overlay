package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestOptions(t *testing.T) {
	for _, args := range [][]string{nil, {"--debug"}, {"--wait-for", "123"}, {"--debug", "--wait-for", "456"}} {
		if _, err := parseOptions(args); err != nil {
			t.Fatal(args, err)
		}
	}
	for _, args := range [][]string{{"--wait-for"}, {"--wait-for", "0"}, {"--wait-for", "-1"}, {"--wait-for", "not-a-pid"}, {"--unknown"}} {
		if _, err := parseOptions(args); err == nil {
			t.Fatal("invalid arguments accepted", args)
		}
	}
}

func TestRuntimeIsolationAndRepair(t *testing.T) {
	base := t.TempDir()
	settings := filepath.Join(base, "settings.json")
	data := []byte("existing user settings")
	if err := os.WriteFile(settings, data, 0600); err != nil {
		t.Fatal(err)
	}
	runtime := filepath.Join(base, "runtime", buildVersion)
	if err := installRuntime(runtime); err != nil {
		t.Fatal(err)
	}
	for _, name := range runtimeFiles {
		expected, _ := payload.ReadFile("payload/" + name)
		actual, err := os.ReadFile(filepath.Join(runtime, name))
		if err != nil || !bytes.Equal(expected, actual) {
			t.Fatal("embedded runtime mismatch", name, err)
		}
	}
	broken := filepath.Join(runtime, "overlay.ps1")
	if err := os.WriteFile(broken, []byte("truncated runtime"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := installRuntime(runtime); err != nil {
		t.Fatal(err)
	}
	actual, _ := os.ReadFile(broken)
	expected, _ := payload.ReadFile("payload/overlay.ps1")
	if !bytes.Equal(actual, expected) {
		t.Fatal("runtime was not repaired")
	}
	if err := installRuntime(runtime); err != nil {
		t.Fatal("repeat extraction", err)
	}
	actual, _ = os.ReadFile(settings)
	if !bytes.Equal(actual, data) {
		t.Fatal("user settings overwritten")
	}
	for _, name := range runtimeFiles {
		if _, err := os.Stat(filepath.Join(runtime, name+".tmp")); !os.IsNotExist(err) {
			t.Fatal("temporary file left behind")
		}
	}
}
