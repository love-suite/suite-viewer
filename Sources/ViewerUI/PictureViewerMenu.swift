import AppKit

extension PictureViewer {
    /// The viewer's menu bar. Shortcuts follow Preview where it has one (Shift+Cmd+A marks up, Cmd+K
    /// crops, Cmd+L and Cmd+R turn), and Windows' keys work too (Ctrl+Z, Ctrl+Y).
    public static func makeMenu() -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Viewer"
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: String, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: Selector((action)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let app = submenu(name)
        add(app, "About \(name)", "orderFrontStandardAboutPanel:")
        app.addItem(.separator())
        add(app, "Hide \(name)", "hide:", "h")
        add(app, "Quit \(name)", "terminate:", "q")

        let file = submenu("File")
        add(file, "Open", "openDocument:", "o")
        file.addItem(.separator())
        add(file, "Save", "saveDocument:", "s")
        add(file, "Save as Copy", "saveDocumentAs:", "s", [.command, .shift])
        add(file, "Revert to Original", "revertToOriginal:")
        file.addItem(.separator())
        add(file, "Open in Preview", "openInPreview")
        add(file, "Move to Trash", "trash", "\u{8}")
        file.addItem(.separator())
        add(file, "Close", "performClose:", "w")

        let edit = submenu("Edit")
        add(edit, "Undo", "undo:", "z")
        add(edit, "Redo", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", "cut:", "x")
        add(edit, "Copy", "copy:", "c")
        add(edit, "Paste", "paste:", "v")
        add(edit, "Duplicate", "duplicate:", "d")
        add(edit, "Delete", "delete:")
        add(edit, "Select All", "selectAll:", "a")
        edit.addItem(.separator())
        add(edit, "Copy All Text", "copyAllText:", "c", [.command, .shift])
        add(edit, "Find Text", "findInPicture:", "f")

        let image = submenu("Image")
        add(image, "Edit and Mark Up", "toggleEditing:", "a", [.command, .shift])
        image.addItem(.separator())
        add(image, "Rotate Left", "rotateLeft:", "l")
        add(image, "Rotate Right", "rotateRight:", "r")
        add(image, "Flip Horizontal", "flipHorizontal:")
        add(image, "Flip Vertical", "flipVertical:")
        add(image, "Crop", "cropPicture:", "k")
        add(image, "Resize Image", "resizeImage:")
        image.addItem(.separator())
        add(image, "Adjust Light and Colour", "showAdjustments:", "c", [.command, .option])
        add(image, "Insert Picture", "insertPicture:")
        let tools = NSMenu(title: "Tools")
        image.addItem(withTitle: "Tools", action: nil, keyEquivalent: "").submenu = tools
        for tool in EditTool.allCases {
            let item = add(tools, tool.title, "pickTool:", String(tool.key), [])
            item.representedObject = tool.rawValue
        }

        let arrange = submenu("Arrange")
        add(arrange, "Bring to Front", "bringToFront:", "]", [.command, .shift])
        add(arrange, "Bring Forward", "bringForward:", "]")
        add(arrange, "Send Backward", "sendBackward:", "[")
        add(arrange, "Send to Back", "sendToBack:", "[", [.command, .shift])
        arrange.addItem(.separator())
        add(arrange, "New Layer", "newLayer:", "n", [.command, .shift])
        add(arrange, "Merge Layer Down", "mergeLayerDown:")
        add(arrange, "Show Layers", "showLayers:")
        add(arrange, "Show History", "showHistory:")

        let view = submenu("View")
        add(view, "Zoom In", "zoomIn", "+")
        add(view, "Zoom Out", "zoomOut", "-")
        add(view, "Fit to Window", "fit", "0")
        add(view, "Actual Size", "actualSize", "1")
        view.addItem(.separator())
        add(view, "Show Text", "toggleText", "t", [.command, .shift])
        view.addItem(.separator())
        add(view, "Enter Full Screen", "toggleFullScreen:", "f", [.command, .control])

        let go = submenu("Go")
        add(go, "Previous Picture", "previous", "\u{F702}", [])
        add(go, "Next Picture", "next", "\u{F703}", [])

        let window = submenu("Window")
        add(window, "Minimize", "performMiniaturize:", "m")
        NSApp.windowsMenu = window
        return main
    }
}
