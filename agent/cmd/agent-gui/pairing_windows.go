package main

import (
	"fmt"
	"os"

	"github.com/lxn/walk"
	. "github.com/lxn/walk/declarative"
)

func (p *panel) showPairing() {
	if p.listen.Text() != p.cfg.Listen || p.token.Text() != p.cfg.Token {
		p.fail(fmt.Errorf("save or discard connection changes before showing the QR code"))
		return
	}
	i := p.network.CurrentIndex()
	if i < 0 || i >= len(p.adapters) {
		p.fail(fmt.Errorf("select a network adapter first"))
		return
	}
	name, _ := os.Hostname()
	payload, err := pairingPayload(p.cfg, p.adapters[i], name)
	if err != nil {
		p.fail(err)
		return
	}
	im, err := pairingImage(payload)
	if err != nil {
		p.fail(err)
		return
	}
	bitmap, err := walk.NewBitmapFromImageForDPI(im, p.window.DPI())
	if err != nil {
		p.fail(fmt.Errorf("could not display QR code"))
		return
	}
	defer bitmap.Dispose()
	var dialog *walk.Dialog
	var closeButton *walk.PushButton
	err = (Dialog{
		AssignTo: &dialog, Title: "Connect phone", FixedSize: true,
		DefaultButton: &closeButton, CancelButton: &closeButton,
		Font:   Font{Family: "Segoe UI", PointSize: 9},
		Layout: VBox{Margins: Margins{Left: 12, Top: 12, Right: 12, Bottom: 12}, Spacing: 8},
		Children: []Widget{
			Label{Text: name, Font: Font{Family: "Segoe UI", PointSize: 12, Bold: true}},
			Label{Text: agentURL(p.cfg, p.adapters[i].IP)},
			ImageView{Image: bitmap, Mode: ImageViewModeIdeal},
			Label{Text: "This code contains your access token.\r\nKeep it private."},
			PushButton{AssignTo: &closeButton, Text: "Close", OnClicked: func() { dialog.Accept() }},
		},
	}).Create(p.window)
	if err != nil {
		p.fail(fmt.Errorf("could not open QR dialog"))
		return
	}
	defer dialog.Dispose()
	dialog.Run()
}
