package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/lxn/walk"
	. "github.com/lxn/walk/declarative"
	"golang.org/x/sys/windows"
)

type panel struct {
	window                                         *walk.MainWindow
	state, uptime, startup                         *walk.Label
	feedback, edits                                *walk.Label
	showToken                                      *walk.CheckBox
	listen, token, url, mac, broadcast             *walk.LineEdit
	network                                        *walk.ComboBox
	logs                                           *walk.TextEdit
	start, stop, save, rotate, startupButton       *walk.PushButton
	discard, refreshButton                         *walk.PushButton
	cfg                                            configuration
	configPath, dir                                string
	adapters                                       []adapter
	child                                          *exec.Cmd
	online, polling, busy, startupEnabled, exiting bool
	startupKnown                                   bool
	taskName                                       string
}

func hiddenCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}

func taskCommand(taskName, script string) *exec.Cmd {
	cmd := hiddenCommand("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.Env = append(os.Environ(), "PC_CONTROL_TASK_NAME="+taskName)
	return cmd
}

func defaultConfigPath(dir, taskName string) string {
	adjacent := filepath.Join(dir, "config.json")
	if _, err := os.Stat(adjacent); err == nil {
		return adjacent
	}
	cmd := taskCommand(taskName, "$task=Get-ScheduledTask -TaskName $env:PC_CONTROL_TASK_NAME -ErrorAction SilentlyContinue; if ($task) { $task.Actions[0].Arguments | ConvertTo-Json -Compress }")
	if out, err := cmd.Output(); err == nil {
		var arguments string
		if json.Unmarshal(out, &arguments) == nil {
			argv, err := windows.DecomposeCommandLine("pc-agent.exe " + arguments)
			if err == nil {
				for i := 1; i+1 < len(argv); i++ {
					if argv[i] == "-config" {
						if _, err := os.Stat(argv[i+1]); err == nil {
							return argv[i+1]
						}
					}
				}
			}
		}
	}
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "PCControl", "config.json")
}

func writeConfig(path string, cfg configuration) error {
	if err := validateConfig(cfg); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	// Protect the temporary file before putting any credentials into it.
	file, err := os.CreateTemp(filepath.Dir(path), ".config-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	file.Close()
	defer os.Remove(temp)
	user := os.Getenv("USERDOMAIN") + "\\" + os.Getenv("USERNAME")
	if out, err := hiddenCommand("icacls.exe", temp, "/inheritance:r", "/grant:r", user+":(F)", "SYSTEM:(F)").CombinedOutput(); err != nil {
		return fmt.Errorf("protect config: %s: %w", out, err)
	}
	if err := os.WriteFile(temp, raw, 0600); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

func (p *panel) log(message string) {
	lines := strings.Split(p.logs.Text(), "\r\n")
	if len(lines) > 150 {
		lines = lines[len(lines)-150:]
	}
	p.logs.SetText(strings.Join(lines, "\r\n") + time.Now().Format("15:04:05") + "  " + message + "\r\n")
	p.logs.SetTextSelection(len(p.logs.Text()), len(p.logs.Text()))
	p.feedback.SetText(message)
}
func (p *panel) fail(err error) {
	p.log(err.Error())
	walk.MsgBox(p.window, "PC Control Agent", err.Error(), walk.MsgBoxIconError)
}
func (p *panel) controls() {
	p.start.SetEnabled(!p.busy && !p.online && p.child == nil)
	p.stop.SetEnabled(!p.busy && (p.online || p.child != nil))
	editable := !p.busy && !p.online && p.child == nil
	p.listen.SetReadOnly(!editable)
	p.token.SetReadOnly(!editable)
	dirty := p.listen.Text() != p.cfg.Listen || p.token.Text() != p.cfg.Token
	p.save.SetEnabled(editable && dirty)
	p.discard.SetEnabled(editable && dirty)
	p.rotate.SetEnabled(editable)
	p.refreshButton.SetEnabled(!p.busy && !p.polling)
	p.startupButton.SetEnabled(!p.busy && p.startupKnown)
	if dirty {
		p.edits.SetText("Unsaved changes")
	} else if !editable {
		p.edits.SetText("Read-only")
	} else {
		p.edits.SetText("Saved")
	}
}
func (p *panel) async(work func() error, done func()) {
	if p.busy {
		return
	}
	p.busy = true
	p.feedback.SetText("Working...")
	p.controls()
	go func() {
		err := work()
		p.window.Synchronize(func() {
			p.busy = false
			if err != nil {
				p.fail(err)
			} else if done != nil {
				done()
			}
			p.controls()
			p.refresh()
		})
	}()
}
func (p *panel) refresh() {
	if p.polling || p.busy {
		return
	}
	p.polling = true
	p.controls()
	cfg := p.cfg
	go func() {
		info, err := fetchStatus(cfg)
		p.window.Synchronize(func() {
			p.polling = false
			if cfg != p.cfg {
				p.refresh()
				return
			}
			previous := p.state.Text()
			p.online = err == nil
			if p.online {
				p.state.SetText("Running")
				p.state.SetTextColor(walk.RGB(18, 107, 89))
				p.uptime.SetText(fmt.Sprintf("Uptime %dd %dh %dm", info.Uptime/86400, (info.Uptime/3600)%24, (info.Uptime/60)%60))
			} else {
				p.state.SetText("Stopped / unreachable")
				p.state.SetTextColor(walk.RGB(96, 106, 118))
				p.uptime.SetText("Uptime --")
				if strings.Contains(fmt.Sprint(err), "HTTP 401") {
					p.state.SetText("Authentication mismatch")
					p.state.SetTextColor(walk.RGB(180, 47, 51))
				}
			}
			if previous != p.state.Text() {
				p.log("Agent status: " + p.state.Text())
			}
			p.controls()
		})
	}()
}
func (p *panel) updateNetwork() {
	if p.network == nil || p.url == nil || p.mac == nil || p.broadcast == nil {
		return
	}
	i := p.network.CurrentIndex()
	if i < 0 || i >= len(p.adapters) {
		return
	}
	a := p.adapters[i]
	p.url.SetText(agentURL(p.cfg, a.IP))
	p.mac.SetText(a.MAC)
	p.broadcast.SetText(a.Broadcast)
}
func (p *panel) saveConfig() {
	cfg := p.cfg
	cfg.Listen = strings.TrimSpace(p.listen.Text())
	cfg.Token = strings.TrimSpace(p.token.Text())
	p.async(func() error { return writeConfig(p.configPath, cfg) }, func() {
		p.cfg = cfg
		p.listen.SetText(cfg.Listen)
		p.token.SetText(cfg.Token)
		p.updateNetwork()
		p.log("Connection settings saved")
	})
}
func (p *panel) startAgent() {
	if p.listen.Text() != p.cfg.Listen || p.token.Text() != p.cfg.Token {
		p.fail(fmt.Errorf("save connection settings before starting the agent"))
		return
	}
	p.async(func() error {
		// A pre-existing listener should never be treated as a stopped agent.
		host, port, _ := net.SplitHostPort(p.cfg.Listen)
		if host == "0.0.0.0" || host == "::" || host == "" {
			host = "127.0.0.1"
		}
		if conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), time.Second); err == nil {
			conn.Close()
			return fmt.Errorf("port %s is already in use; check the existing agent or change the port", port)
		}
		cmd := hiddenCommand(filepath.Join(p.dir, "pc-agent.exe"), "-config", p.configPath)
		cmd.Dir = p.dir
		logFile, err := os.OpenFile(filepath.Join(filepath.Dir(p.configPath), "agent.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		cmd.Stdout = logFile
		cmd.Stderr = logFile
		err = cmd.Start()
		logFile.Close()
		if err != nil {
			return err
		}
		p.window.Synchronize(func() { p.child = cmd; p.log("Agent started") })
		go func() {
			err := cmd.Wait()
			p.window.Synchronize(func() {
				if p.child == cmd {
					p.child = nil
				}
				if err != nil {
					p.log("Agent exited: " + err.Error())
				}
				p.controls()
				p.refresh()
			})
		}()
		return nil
	}, nil)
}
func (p *panel) stopAgent() {
	child := p.child
	cfg := p.cfg
	p.async(func() error {
		if supported, err := requestAgentStop(cfg); err == nil && supported {
			return nil
		} else if err != nil && child == nil {
			return err
		}
		if child != nil {
			return child.Process.Kill()
		}
		cmd := taskCommand(p.taskName, "$ErrorActionPreference='Stop'; $t=Get-ScheduledTask -TaskName $env:PC_CONTROL_TASK_NAME; if ($t.State -ne 'Running') { throw 'The running agent was started elsewhere. Stop it from its original launcher.' }; Stop-ScheduledTask -TaskName $env:PC_CONTROL_TASK_NAME")
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s", strings.TrimSpace(string(out)))
		}
		return nil
	}, func() { p.log("Agent stop requested") })
}
func (p *panel) toggleStartup() {
	enable := !p.startupEnabled
	p.async(func() error {
		var cmd *exec.Cmd
		if enable {
			cmd = hiddenCommand("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(p.dir, "install.ps1"), "-SkipBuild", "-NoStart", "-ConfigPath", p.configPath, "-TaskName", p.taskName)
		} else {
			// Removing startup must not interrupt an active agent.
			cmd = taskCommand(p.taskName, "$ErrorActionPreference='Stop'; Unregister-ScheduledTask -TaskName $env:PC_CONTROL_TASK_NAME -Confirm:$false")
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("startup settings: %s", strings.TrimSpace(string(out)))
		}
		return nil
	}, func() { p.setStartup(enable); p.log("Startup preference saved") })
}
func (p *panel) setStartup(enabled bool) {
	p.startupKnown = true
	p.startupEnabled = enabled
	if enabled {
		p.startup.SetText("Enabled")
		p.startupButton.SetText("Disable startup")
	} else {
		p.startup.SetText("Disabled")
		p.startupButton.SetText("Enable startup")
	}
	p.controls()
}
func (p *panel) copy(name, value string) {
	if value == "" {
		p.log(name + " unavailable")
		return
	}
	if err := walk.Clipboard().SetText(value); err != nil {
		p.fail(err)
	} else {
		p.log(name + " copied")
	}
}

func main() {
	exe, _ := os.Executable()
	dir := filepath.Dir(exe)
	path := flag.String("config", "", "configuration file")
	taskName := flag.String("task-name", "PC Control Agent", "scheduled task name")
	flag.Parse()
	if *path == "" {
		*path = defaultConfigPath(dir, *taskName)
	}
	absolute, err := filepath.Abs(*path)
	if err != nil {
		return
	}
	mutexName, _ := windows.UTF16PtrFromString("Local\\PCControlGUI-" + strings.ReplaceAll(absolute, "\\", "/"))
	mutex, err := windows.CreateMutex(nil, false, mutexName)
	if mutex != 0 {
		defer windows.CloseHandle(mutex)
	}
	if err == windows.ERROR_ALREADY_EXISTS {
		walk.MsgBox(nil, "PC Control Agent", "The control panel is already open. Check the system tray.", walk.MsgBoxIconInformation)
		return
	}
	if err != nil {
		walk.MsgBox(nil, "PC Control Agent", err.Error(), walk.MsgBoxIconError)
		return
	}
	cfg, err := readConfig(absolute)
	if os.IsNotExist(err) {
		cfg.Listen = "0.0.0.0:8787"
		cfg.Token, err = newToken()
		if err == nil {
			err = writeConfig(absolute, cfg)
		}
	}
	if err != nil {
		walk.MsgBox(nil, "PC Control Agent", err.Error(), walk.MsgBoxIconError)
		return
	}
	p := &panel{cfg: cfg, configPath: absolute, dir: dir, adapters: networkAdapters(), taskName: *taskName}
	names := []string{}
	for _, a := range p.adapters {
		names = append(names, a.Name)
	}
	computer, _ := os.Hostname()
	icon, err := walk.NewIconFromSysDLL("shell32", 15)
	if err != nil {
		walk.MsgBox(nil, "PC Control Agent", err.Error(), walk.MsgBoxIconError)
		return
	}
	copyFont := Font{Family: "Segoe MDL2 Assets", PointSize: 11}
	muted := walk.RGB(96, 106, 118)
	heading := Font{Family: "Segoe UI", PointSize: 10, Bold: true}
	copyButton := func(name string, value func() string) PushButton {
		return PushButton{
			Text: "\uE8C8", Font: copyFont, Accessibility: Accessibility{Name: "Copy " + name}, ToolTipText: "Copy " + name,
			MinSize: Size{Width: 28, Height: 24}, MaxSize: Size{Width: 28, Height: 24}, OnClicked: func() { p.copy(name, value()) },
		}
	}
	err = (MainWindow{
		AssignTo: &p.window, Title: "PC Control Agent", Icon: icon, Size: Size{Width: 520, Height: 600}, MinSize: Size{Width: 520, Height: 600}, Font: Font{Family: "Segoe UI", PointSize: 9}, Background: SolidColorBrush{Color: walk.RGB(255, 255, 255)}, Layout: VBox{Margins: Margins{Left: 12, Top: 8, Right: 12, Bottom: 8}, Spacing: 3},
		Children: []Widget{
			Composite{MaxSize: Size{Height: 50}, Layout: HBox{MarginsZero: true}, Children: []Widget{
				Composite{Layout: VBox{MarginsZero: true, Spacing: 4}, Children: []Widget{Label{Text: computer, Font: Font{Family: "Segoe UI", PointSize: 18, Bold: true}}, Label{Text: "Windows agent", TextColor: muted}}}, HSpacer{},
				Composite{Layout: VBox{MarginsZero: true, Spacing: 4}, Children: []Widget{Label{AssignTo: &p.state, Text: "Checking agent...", Font: heading, TextColor: muted, TextAlignment: AlignFar}, Label{AssignTo: &p.uptime, Text: "Uptime --", TextColor: muted, TextAlignment: AlignFar}}},
			}},
			Composite{MaxSize: Size{Height: 38}, Layout: HBox{MarginsZero: true}, Children: []Widget{PushButton{AssignTo: &p.start, Text: "Start agent", MinSize: Size{Width: 110, Height: 32}, MaxSize: Size{Width: 110, Height: 32}, OnClicked: p.startAgent}, PushButton{AssignTo: &p.stop, Text: "Stop agent", MinSize: Size{Width: 110, Height: 32}, MaxSize: Size{Width: 110, Height: 32}, OnClicked: p.stopAgent}, HSpacer{}, PushButton{AssignTo: &p.refreshButton, Text: "\uE72C", Font: copyFont, MinSize: Size{Width: 34, Height: 32}, MaxSize: Size{Width: 34, Height: 32}, Accessibility: Accessibility{Name: "Refresh status"}, ToolTipText: "Refresh status", OnClicked: p.refresh}, PushButton{Text: "Hide to tray", MinSize: Size{Width: 110, Height: 32}, MaxSize: Size{Width: 110, Height: 32}, OnClicked: func() { p.window.Hide() }}}},
			Composite{MinSize: Size{Height: 1}, MaxSize: Size{Height: 1}, Background: SolidColorBrush{Color: walk.RGB(224, 228, 232)}},
			Composite{Layout: HBox{MarginsZero: true}, Children: []Widget{Label{Text: "Phone connection", Font: heading}, HSpacer{}, PushButton{Text: "\uED14", Font: copyFont, MinSize: Size{Width: 28, Height: 24}, MaxSize: Size{Width: 28, Height: 24}, Accessibility: Accessibility{Name: "Show QR code"}, ToolTipText: "Show QR code", OnClicked: p.showPairing}}},
			Composite{Layout: Grid{Columns: 3, Spacing: 3, MarginsZero: true}, Children: []Widget{
				Label{Text: "Network adapter", MinSize: Size{Width: 118}, TextColor: muted}, ComboBox{AssignTo: &p.network, Accessibility: Accessibility{Name: "Network adapter selection"}, Model: names, CurrentIndex: 0, ColumnSpan: 2, OnCurrentIndexChanged: p.updateNetwork},
				Label{Text: "Agent URL", TextColor: muted}, LineEdit{AssignTo: &p.url, Accessibility: Accessibility{Name: "Agent URL value"}, ReadOnly: true}, copyButton("agent URL", func() string { return p.url.Text() }),
				Label{Text: "MAC address", TextColor: muted}, LineEdit{AssignTo: &p.mac, Accessibility: Accessibility{Name: "MAC address value"}, ReadOnly: true}, copyButton("MAC address", func() string { return p.mac.Text() }),
				Label{Text: "Broadcast address", TextColor: muted}, LineEdit{AssignTo: &p.broadcast, Accessibility: Accessibility{Name: "Broadcast address value"}, ReadOnly: true}, copyButton("broadcast address", func() string { return p.broadcast.Text() }),
				Label{Text: "Access token", TextColor: muted}, LineEdit{AssignTo: &p.token, Accessibility: Accessibility{Name: "Access token value"}, Text: cfg.Token, PasswordMode: true}, copyButton("access token", func() string { return p.token.Text() }),
				Label{}, CheckBox{AssignTo: &p.showToken, Text: "Show token", OnCheckedChanged: func() {
					if p.token != nil && p.showToken != nil {
						p.token.SetPasswordMode(!p.showToken.Checked())
					}
				}}, Label{},
			}},
			Composite{MinSize: Size{Height: 1}, MaxSize: Size{Height: 1}, Background: SolidColorBrush{Color: walk.RGB(224, 228, 232)}},
			Composite{Layout: HBox{MarginsZero: true}, Children: []Widget{Label{Text: "Agent settings", Font: heading}, HSpacer{}, Label{AssignTo: &p.edits, Text: "Saved", TextColor: muted}}},
			Composite{Layout: Grid{Columns: 2, Spacing: 3, MarginsZero: true}, Children: []Widget{
				Label{Text: "Listen address", MinSize: Size{Width: 118}, TextColor: muted}, LineEdit{AssignTo: &p.listen, Accessibility: Accessibility{Name: "Listen address value"}, Text: cfg.Listen},
				Label{Text: "Start at sign-in", TextColor: muted}, Composite{Layout: HBox{MarginsZero: true}, Children: []Widget{Label{AssignTo: &p.startup, Text: "Checking..."}, HSpacer{}, PushButton{AssignTo: &p.startupButton, Text: "Enable startup", MinSize: Size{Width: 140, Height: 30}, OnClicked: p.toggleStartup}}},
				Label{Text: "Transport", TextColor: muted}, Label{Text: map[bool]string{true: "HTTPS", false: "HTTP"}[cfg.Cert != ""]},
			}},
			Composite{MaxSize: Size{Height: 34}, Layout: HBox{MarginsZero: true}, Children: []Widget{HSpacer{}, PushButton{AssignTo: &p.discard, Text: "Discard changes", MinSize: Size{Width: 132, Height: 30}, MaxSize: Size{Width: 132, Height: 30}, ToolTipText: "Restore saved listen address and token", OnClicked: func() {
				if !p.busy && !p.online && p.child == nil {
					p.listen.SetText(p.cfg.Listen)
					p.token.SetText(p.cfg.Token)
					p.showToken.SetChecked(false)
					p.log("Changes discarded")
				}
			}}, PushButton{AssignTo: &p.rotate, Text: "Generate token", MinSize: Size{Width: 128, Height: 30}, MaxSize: Size{Width: 128, Height: 30}, ToolTipText: "Generate a new unsaved access token", OnClicked: func() {
				token, err := newToken()
				if err != nil {
					p.fail(err)
				} else {
					p.token.SetText(token)
					p.showToken.SetChecked(false)
					p.log("New access token generated (unsaved)")
				}
			}}, PushButton{AssignTo: &p.save, Text: "Save settings", MinSize: Size{Width: 116, Height: 30}, MaxSize: Size{Width: 116, Height: 30}, OnClicked: p.saveConfig},
			}},
			Composite{MinSize: Size{Height: 1}, MaxSize: Size{Height: 1}, Background: SolidColorBrush{Color: walk.RGB(224, 228, 232)}},
			Composite{MaxSize: Size{Height: 30}, Layout: HBox{MarginsZero: true}, Children: []Widget{Label{Text: "Activity", Font: heading}, HSpacer{}, PushButton{Text: "Clear", ToolTipText: "Clear visible activity", OnClicked: func() { p.logs.SetText(""); p.feedback.SetText("Activity cleared") }}}},
			TextEdit{AssignTo: &p.logs, Accessibility: Accessibility{Name: "Activity log"}, ReadOnly: true, VScroll: true, MinSize: Size{Height: 32}, StretchFactor: 1, Font: Font{Family: "Segoe UI", PointSize: 9}},
			Composite{MaxSize: Size{Height: 34}, Layout: HBox{MarginsZero: true}, Children: []Widget{PushButton{Text: "Open log", MinSize: Size{Width: 100, Height: 30}, MaxSize: Size{Width: 100, Height: 30}, OnClicked: func() {
				path := filepath.Join(filepath.Dir(p.configPath), "agent.log")
				file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
				if err != nil {
					p.fail(err)
					return
				}
				file.Close()
				cmd := exec.Command("notepad.exe", path)
				if err := cmd.Start(); err != nil {
					p.fail(err)
				} else {
					p.log("Log opened")
					go cmd.Wait()
				}
			}}, Label{AssignTo: &p.feedback, Text: "Ready", TextColor: walk.RGB(18, 107, 89), EllipsisMode: EllipsisEnd, StretchFactor: 1}, HSpacer{}, PushButton{Text: "Exit control panel", MinSize: Size{Width: 150, Height: 30}, MaxSize: Size{Width: 150, Height: 30}, OnClicked: func() { p.exiting = true; p.window.Close() }}}},
		},
	}).Create()
	if err != nil {
		walk.MsgBox(nil, "PC Control Agent", err.Error(), walk.MsgBoxIconError)
		return
	}
	defer p.window.Dispose()
	p.listen.TextChanged().Attach(p.controls)
	p.token.TextChanged().Attach(p.controls)
	tray, err := walk.NewNotifyIcon(p.window)
	if err != nil {
		p.fail(err)
		return
	}
	defer tray.Dispose()
	tray.SetIcon(icon)
	trayTip := "PC Control Agent"
	if p.taskName != "PC Control Agent" {
		trayTip += " (" + p.taskName + ")"
	}
	tray.SetToolTip(trayTip)
	tray.SetVisible(true)
	show := func() { p.window.Show(); p.window.Activate() }
	tray.MouseDown().Attach(func(x, y int, button walk.MouseButton) {
		if button == walk.LeftButton {
			show()
		}
	})
	action := walk.NewAction()
	action.SetText("Open control panel")
	action.Triggered().Attach(show)
	tray.ContextMenu().Actions().Add(action)
	exit := walk.NewAction()
	exit.SetText("Exit control panel")
	exit.Triggered().Attach(func() { p.exiting = true; p.window.Close() })
	tray.ContextMenu().Actions().Add(exit)
	p.window.Closing().Attach(func(canceled *bool, reason walk.CloseReason) {
		if !p.exiting {
			*canceled = true
			p.window.Hide()
		}
	})
	p.updateNetwork()
	p.log("Control panel opened")
	p.controls()
	p.refresh()
	go func() {
		cmd := taskCommand(p.taskName, "if (Get-ScheduledTask -TaskName $env:PC_CONTROL_TASK_NAME -ErrorAction SilentlyContinue) { exit 0 }; exit 1")
		err := cmd.Run()
		p.window.Synchronize(func() { p.setStartup(err == nil) })
	}()
	done := make(chan struct{})
	defer close(done)
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				p.window.Synchronize(p.refresh)
			case <-done:
				return
			}
		}
	}()
	p.window.Run()
}
