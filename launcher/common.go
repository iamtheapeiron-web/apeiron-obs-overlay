package main

import (
	"bytes"
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

const buildVersion = "0.2-beta1-build4"

//go:embed payload/*
var payload embed.FS

var runtimeFiles = []string{"overlay.ps1", "APEIRON.ico", "APEIRON_icon.png"}

type options struct {
	debug   bool
	waitPID uint32
}

func parseOptions(args []string) (options, error) {
	var result options
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--debug":
			result.debug = true
		case "--wait-for":
			if i+1 == len(args) {
				return result, fmt.Errorf("--wait-for requires a process ID")
			}
			i++
			n, err := strconv.ParseUint(args[i], 10, 32)
			if err != nil || n == 0 {
				return result, fmt.Errorf("invalid restart process ID")
			}
			result.waitPID = uint32(n)
		default:
			return result, fmt.Errorf("unknown option: %s", args[i])
		}
	}
	return result, nil
}

func installRuntime(directory string) error {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	for _, name := range runtimeFiles {
		data, err := payload.ReadFile("payload/" + name)
		if err != nil {
			return err
		}
		path := filepath.Join(directory, name)
		existing, err := os.ReadFile(path)
		if err == nil && bytes.Equal(existing, data) {
			continue
		}
		temp := path + ".tmp"
		if err = os.WriteFile(temp, data, 0600); err != nil {
			return err
		}
		if err = os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		if err = os.Rename(temp, path); err != nil {
			return err
		}
	}
	return nil
}
