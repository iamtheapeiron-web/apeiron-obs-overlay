//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"unsafe"
)

var kernel = syscall.NewLazyDLL("kernel32.dll")
var user = syscall.NewLazyDLL("user32.dll")
var createMutex = kernel.NewProc("CreateMutexW")
var waitObject = kernel.NewProc("WaitForSingleObject")
var releaseMutex = kernel.NewProc("ReleaseMutex")
var messageBox = user.NewProc("MessageBoxW")

func dialog(message string, failure bool) {
	text, _ := syscall.UTF16PtrFromString(message)
	title, _ := syscall.UTF16PtrFromString("APEIRON OBS Overlay")
	var flags uintptr
	if failure {
		flags = 0x10
	} else {
		flags = 0x40
	}
	messageBox.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), flags)
}

func run() error {
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		return err
	}
	if opts.waitPID != 0 {
		// Elevated restart waits for the old launcher to restore Hold and exit.
		process, err := syscall.OpenProcess(0x00100000, false, opts.waitPID)
		if err == nil {
			result, _, _ := waitObject.Call(uintptr(process), 20000)
			syscall.CloseHandle(process)
			if result != 0 {
				return fmt.Errorf("the previous instance has not exited; use its tray icon to close it")
			}
		}
	}
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return err
	}
	account, err := token.GetTokenUser()
	token.Close()
	if err != nil {
		return err
	}
	sid, err := account.User.Sid.String()
	if err != nil {
		return err
	}
	name, _ := syscall.UTF16PtrFromString("Local\\APEIRON.OBSOverlay.Launcher." + sid)
	handle, _, err := createMutex.Call(0, 0, uintptr(unsafe.Pointer(name)))
	if handle == 0 {
		return fmt.Errorf("cannot create the single-instance guard: %v", err)
	}
	defer syscall.CloseHandle(syscall.Handle(handle))
	ownership, _, _ := waitObject.Call(handle, 0)
	if ownership == 258 {
		dialog("APEIRON OBS Overlay is already running. Open Settings from its tray icon.", false)
		return nil
	}
	if ownership != 0 && ownership != 128 {
		return fmt.Errorf("cannot acquire the single-instance guard")
	}
	defer releaseMutex.Call(handle)

	local := os.Getenv("LOCALAPPDATA")
	if local == "" {
		return fmt.Errorf("Windows LOCALAPPDATA is unavailable")
	}
	base := filepath.Join(local, "APEIRON_OBS_Overlay")
	directory := filepath.Join(base, "runtime", buildVersion)
	if err = installRuntime(directory); err != nil {
		return fmt.Errorf("cannot prepare the application: %w", err)
	}
	launcher, err := os.Executable()
	if err != nil {
		return err
	}
	launcher, err = filepath.Abs(launcher)
	if err != nil {
		return err
	}
	system := os.Getenv("SystemRoot")
	if system == "" {
		return fmt.Errorf("Windows SystemRoot is unavailable")
	}
	powershell := filepath.Join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	args := []string{"-NoLogo", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(directory, "overlay.ps1")}
	if opts.debug {
		args = append(args, "-DebugMode")
	}
	command := exec.Command(powershell, args...)
	command.Dir = directory
	command.Env = append(os.Environ(),
		"APEIRON_LAUNCHER_PATH="+launcher,
		"APEIRON_LAUNCHER_PID="+strconv.Itoa(os.Getpid()),
		"APEIRON_BUILD_VERSION="+buildVersion)
	if opts.debug {
		// A GUI parent otherwise gives os/exec null standard handles even when
		// CREATE_NEW_CONSOLE is requested. Attach real console handles.
		kernel.NewProc("AllocConsole").Call()
		consoleOut, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0)
		if err != nil {
			return err
		}
		defer consoleOut.Close()
		consoleIn, err := os.OpenFile("CONIN$", os.O_RDONLY, 0)
		if err != nil {
			return err
		}
		defer consoleIn.Close()
		command.Stdout = consoleOut
		command.Stderr = consoleOut
		command.Stdin = consoleIn
		command.Args = append(command.Args[:1], append([]string{"-NoExit"}, command.Args[1:]...)...)
		command.SysProcAttr = &syscall.SysProcAttr{}
	} else {
		command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
		log, err := os.OpenFile(filepath.Join(base, "last-run.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
		if err != nil {
			return err
		}
		defer log.Close()
		command.Stdout = log
		command.Stderr = log
	}
	if err = command.Run(); err != nil {
		return fmt.Errorf("the application could not start or stopped unexpectedly (%v). Details: %s", err, filepath.Join(base, "last-run.log"))
	}
	return nil
}

func main() {
	// Windows mutex ownership is per native thread, including release.
	runtime.LockOSThread()
	if err := run(); err != nil {
		dialog(err.Error(), true)
		os.Exit(1)
	}
}
