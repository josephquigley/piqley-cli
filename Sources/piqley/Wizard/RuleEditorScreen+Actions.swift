import PiqleyCore
import TermKit

// MARK: - Action Input (shared for emit/write)

extension RuleEditorScreen {
    enum ActionType { case emit, write }

    struct ActionInputContext {
        let title: String
        let contextText: String
        let actionType: ActionType
        var builder: RuleBuilder
        let onDone: (RuleBuilder) -> Void
        let onCancel: () -> Void

        func with(builder newBuilder: RuleBuilder) -> ActionInputContext {
            ActionInputContext(
                title: title, contextText: contextText, actionType: actionType,
                builder: newBuilder, onDone: onDone, onCancel: onCancel
            )
        }
    }

    func showActionInputWithContext(_ inputCtx: ActionInputContext) {
        let actions = context.validActions()
        let actionItems = actions.map { action -> String in
            switch action {
            case "add": return "add -- add values to a field"
            case "remove": return "remove -- remove values from a field"
            case "replace": return "replace -- replace patterns in a field"
            case "removeField": return "removeField -- remove an entire field"
            case "clone": return "clone -- copy values from another source"
            default: return action
            }
        }

        let top = Toplevel()
        top.fill()

        let win = WizardWindow(inputCtx.title)
        win.fill()
        top.addSubview(win)

        let ctxLabel = Label(inputCtx.contextText)
        ctxLabel.x = Pos.at(0)
        ctxLabel.y = Pos.at(0)
        ctxLabel.width = Dim.fill()
        win.addSubview(ctxLabel)

        let hint = Label("  Select an action:")
        hint.x = Pos.at(0)
        hint.y = Pos.at(2)
        hint.width = Dim.fill()
        win.addSubview(hint)

        let list = ListView(items: actionItems)
        list.x = Pos.at(1)
        list.y = Pos.at(4)
        list.width = Dim.fill(1)
        list.height = Dim.fill(3)
        list.allowMarking = false
        list.selectedMarker = "> "
        win.addSubview(list)

        let footer = Label("  \u{23CE} select   Esc cancel")
        footer.x = Pos.at(0)
        footer.y = Pos.bottom(of: list) + 1
        footer.width = Dim.fill()
        win.addSubview(footer)

        list.activate = { [weak self] index in
            guard let self, index < actions.count else { return true }
            let action = actions[index]
            Application.requestStop()
            showActionDetail(action: action, inputCtx: inputCtx)
            return true
        }

        win.onKey = { event in
            if event.key == .esc {
                Application.requestStop()
                inputCtx.onCancel()
                return true
            }
            return false
        }

        Application.present(top: top)
    }

    func showActionDetail(action: String, inputCtx: ActionInputContext) {
        switch action {
        case "add", "remove":
            showValuesInput(action: action, inputCtx: inputCtx)
        case "replace":
            showReplaceInput(inputCtx: inputCtx)
        case "removeField":
            showRemoveFieldInput(inputCtx: inputCtx)
        case "clone":
            showCloneInput(inputCtx: inputCtx)
        default:
            inputCtx.onCancel()
        }
    }

    // MARK: - Action Detail Inputs

    func showValuesInput(action: String, inputCtx: ActionInputContext) {
        let dialog = Dialog(title: "\(action) Action", width: 60, height: 14, buttons: [])

        let fieldLabel = Label("Target field:")
        fieldLabel.x = Pos.at(1)
        fieldLabel.y = Pos.at(1)
        dialog.addSubview(fieldLabel)

        let fieldInput = TextField("")
        fieldInput.x = Pos.at(15)
        fieldInput.y = Pos.at(1)
        fieldInput.width = Dim.fill(1)
        dialog.addSubview(fieldInput)

        let valuesLabel = Label("Values (comma-separated):")
        valuesLabel.x = Pos.at(1)
        valuesLabel.y = Pos.at(3)
        valuesLabel.width = Dim.fill(1)
        dialog.addSubview(valuesLabel)

        let valuesInput = TextField("")
        valuesInput.x = Pos.at(1)
        valuesInput.y = Pos.at(4)
        valuesInput.width = Dim.fill(1)
        dialog.addSubview(valuesInput)

        let errorLabel = Label("")
        errorLabel.x = Pos.at(1)
        errorLabel.y = Pos.at(6)
        errorLabel.width = Dim.fill(1)
        dialog.addSubview(errorLabel)

        let okBtn = Button("OK")
        let cancelBtn = Button("Cancel") {
            Application.requestStop()
            inputCtx.onCancel()
        }

        okBtn.clicked = { [weak self] _ in
            guard let self else { return }
            let field = fieldInput.text.trimmingCharacters(in: .whitespaces)
            let rawValues = valuesInput.text
            let values = rawValues.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let config = EmitConfig(
                action: action, field: field, values: values,
                replacements: nil, source: nil
            )

            var mutableBuilder = inputCtx.builder
            let result = inputCtx.actionType == .emit
                ? mutableBuilder.addEmit(config)
                : mutableBuilder.addWrite(config)

            switch result {
            case .success:
                Application.requestStop()
                askAddAnother(inputCtx: inputCtx.with(builder: mutableBuilder))
            case let .failure(error):
                errorLabel.text = error.errorDescription ?? "Invalid"
            }
        }

        dialog.addButton(okBtn)
        dialog.addButton(cancelBtn)
        Application.present(top: dialog)
    }

    func showReplaceInput(inputCtx: ActionInputContext) {
        let dialog = Dialog(title: "Replace Action", width: 60, height: 14, buttons: [])

        let fieldLabel = Label("Target field:")
        fieldLabel.x = Pos.at(1)
        fieldLabel.y = Pos.at(1)
        dialog.addSubview(fieldLabel)

        let fieldInput = TextField("")
        fieldInput.x = Pos.at(15)
        fieldInput.y = Pos.at(1)
        fieldInput.width = Dim.fill(1)
        dialog.addSubview(fieldInput)

        let patternLabel = Label("Match pattern:")
        patternLabel.x = Pos.at(1)
        patternLabel.y = Pos.at(3)
        dialog.addSubview(patternLabel)

        let patternInput = TextField("")
        patternInput.x = Pos.at(16)
        patternInput.y = Pos.at(3)
        patternInput.width = Dim.fill(1)
        dialog.addSubview(patternInput)

        let replLabel = Label("Replacement:")
        replLabel.x = Pos.at(1)
        replLabel.y = Pos.at(5)
        dialog.addSubview(replLabel)

        let replInput = TextField("")
        replInput.x = Pos.at(16)
        replInput.y = Pos.at(5)
        replInput.width = Dim.fill(1)
        dialog.addSubview(replInput)

        let errorLabel = Label("")
        errorLabel.x = Pos.at(1)
        errorLabel.y = Pos.at(7)
        errorLabel.width = Dim.fill(1)
        dialog.addSubview(errorLabel)

        let okBtn = Button("OK")
        let cancelBtn = Button("Cancel") {
            Application.requestStop()
            inputCtx.onCancel()
        }

        okBtn.clicked = { [weak self] _ in
            guard let self else { return }
            let field = fieldInput.text.trimmingCharacters(in: .whitespaces)
            let pat = patternInput.text.trimmingCharacters(in: .whitespaces)
            let repl = replInput.text

            let config = EmitConfig(
                action: "replace", field: field, values: nil,
                replacements: [Replacement(pattern: pat, replacement: repl)],
                source: nil
            )

            var mutableBuilder = inputCtx.builder
            let result = inputCtx.actionType == .emit
                ? mutableBuilder.addEmit(config)
                : mutableBuilder.addWrite(config)

            switch result {
            case .success:
                Application.requestStop()
                askAddAnother(inputCtx: inputCtx.with(builder: mutableBuilder))
            case let .failure(error):
                errorLabel.text = error.errorDescription ?? "Invalid"
            }
        }

        dialog.addButton(okBtn)
        dialog.addButton(cancelBtn)
        Application.present(top: dialog)
    }

    func showRemoveFieldInput(inputCtx: ActionInputContext) {
        let dialog = Dialog(title: "Remove Field Action", width: 60, height: 10, buttons: [])

        let fieldLabel = Label("Field to remove (or * for all):")
        fieldLabel.x = Pos.at(1)
        fieldLabel.y = Pos.at(1)
        fieldLabel.width = Dim.fill(1)
        dialog.addSubview(fieldLabel)

        let fieldInput = TextField("")
        fieldInput.x = Pos.at(1)
        fieldInput.y = Pos.at(2)
        fieldInput.width = Dim.fill(1)
        dialog.addSubview(fieldInput)

        let errorLabel = Label("")
        errorLabel.x = Pos.at(1)
        errorLabel.y = Pos.at(4)
        errorLabel.width = Dim.fill(1)
        dialog.addSubview(errorLabel)

        let okBtn = Button("OK")
        let cancelBtn = Button("Cancel") {
            Application.requestStop()
            inputCtx.onCancel()
        }

        okBtn.clicked = { [weak self] _ in
            guard let self else { return }
            let field = fieldInput.text.trimmingCharacters(in: .whitespaces)
            let config = EmitConfig(
                action: "removeField", field: field, values: nil,
                replacements: nil, source: nil
            )

            var mutableBuilder = inputCtx.builder
            let result = inputCtx.actionType == .emit
                ? mutableBuilder.addEmit(config)
                : mutableBuilder.addWrite(config)

            switch result {
            case .success:
                Application.requestStop()
                askAddAnother(inputCtx: inputCtx.with(builder: mutableBuilder))
            case let .failure(error):
                errorLabel.text = error.errorDescription ?? "Invalid"
            }
        }

        dialog.addButton(okBtn)
        dialog.addButton(cancelBtn)
        Application.present(top: dialog)
    }

    func showCloneInput(inputCtx: ActionInputContext) {
        let dialog = Dialog(title: "Clone Action", width: 60, height: 12, buttons: [])

        let fieldLabel = Label("Target field (or * for all):")
        fieldLabel.x = Pos.at(1)
        fieldLabel.y = Pos.at(1)
        dialog.addSubview(fieldLabel)

        let fieldInput = TextField("")
        fieldInput.x = Pos.at(1)
        fieldInput.y = Pos.at(2)
        fieldInput.width = Dim.fill(1)
        dialog.addSubview(fieldInput)

        let sourceLabel = Label("Source (e.g. original:IPTC:Keywords):")
        sourceLabel.x = Pos.at(1)
        sourceLabel.y = Pos.at(4)
        sourceLabel.width = Dim.fill(1)
        dialog.addSubview(sourceLabel)

        let sourceInput = TextField("")
        sourceInput.x = Pos.at(1)
        sourceInput.y = Pos.at(5)
        sourceInput.width = Dim.fill(1)
        dialog.addSubview(sourceInput)

        let errorLabel = Label("")
        errorLabel.x = Pos.at(1)
        errorLabel.y = Pos.at(7)
        errorLabel.width = Dim.fill(1)
        dialog.addSubview(errorLabel)

        let okBtn = Button("OK")
        let cancelBtn = Button("Cancel") {
            Application.requestStop()
            inputCtx.onCancel()
        }

        okBtn.clicked = { [weak self] _ in
            guard let self else { return }
            let field = fieldInput.text.trimmingCharacters(in: .whitespaces)
            let source = sourceInput.text.trimmingCharacters(in: .whitespaces)
            let config = EmitConfig(
                action: "clone", field: field, values: nil,
                replacements: nil, source: source
            )

            var mutableBuilder = inputCtx.builder
            let result = inputCtx.actionType == .emit
                ? mutableBuilder.addEmit(config)
                : mutableBuilder.addWrite(config)

            switch result {
            case .success:
                Application.requestStop()
                askAddAnother(inputCtx: inputCtx.with(builder: mutableBuilder))
            case let .failure(error):
                errorLabel.text = error.errorDescription ?? "Invalid"
            }
        }

        dialog.addButton(okBtn)
        dialog.addButton(cancelBtn)
        Application.present(top: dialog)
    }

    // MARK: - "Add another?" prompt

    func askAddAnother(inputCtx: ActionInputContext) {
        let typeName = inputCtx.actionType == .emit ? "emit" : "write"
        let dialog = Dialog(title: "Add another \(typeName) action?", width: 40, height: 7, buttons: [
            Button("Yes") { [weak self] in
                guard let self else { return }
                Application.requestStop()
                showActionInputWithContext(inputCtx)
            },
            Button("No, continue") {
                Application.requestStop()
                inputCtx.onDone(inputCtx.builder)
            },
        ])
        let msg = Label("Add another \(typeName) action?")
        msg.x = Pos.at(1)
        msg.y = Pos.at(1)
        msg.width = Dim.fill(1)
        dialog.addSubview(msg)
        Application.present(top: dialog)
    }

    // MARK: - Helpers

    static func categoryName(_ category: FieldCategory) -> String {
        switch category {
        case .custom: "Custom"
        case .exif: "EXIF"
        case .iptc: "IPTC"
        case .xmp: "XMP"
        case .tiff: "TIFF"
        }
    }

    static func describeEmit(_ config: EmitConfig) -> String {
        let action = config.action ?? "add"
        if let values = config.values {
            return "\(action) \(config.field) = [\(values.joined(separator: ", "))]"
        } else if let replacements = config.replacements {
            let pairs = replacements.map { "\($0.pattern) -> \($0.replacement)" }
            return "replace \(config.field): \(pairs.joined(separator: "; "))"
        } else if let source = config.source {
            return "clone \(config.field) from \(source)"
        }
        return "\(action) \(config.field)"
    }
}
