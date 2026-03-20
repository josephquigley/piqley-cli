import PiqleyCore
import TermKit

// MARK: - Steps 4–6: Emit Actions, Write Actions, Confirm

extension RuleEditorScreen {
    func showEmitActions(
        fieldName: String,
        pattern: String,
        builder: RuleBuilder,
        onComplete: @escaping (Rule?) -> Void
    ) {
        let inputCtx = ActionInputContext(
            title: "New Rule: Emit Actions",
            contextText: "  Match: \(fieldName) ~ \(pattern)",
            actionType: .emit,
            builder: builder,
            onDone: { [weak self] updatedBuilder in
                guard let self else { return }
                showWriteActions(fieldName: fieldName, pattern: pattern,
                                 builder: updatedBuilder, onComplete: onComplete)
            },
            onCancel: { onComplete(nil) }
        )
        showActionInputWithContext(inputCtx)
    }

    func showWriteActions(
        fieldName: String,
        pattern: String,
        builder: RuleBuilder,
        onComplete: @escaping (Rule?) -> Void
    ) {
        let dialog = Dialog(title: "Write Actions", width: 50, height: 8, buttons: [
            Button("Add Write Actions") { [weak self] in
                guard let self else { return }
                Application.requestStop()
                let writeCtx = ActionInputContext(
                    title: "New Rule: Write Actions",
                    contextText: "  Match: \(fieldName) ~ \(pattern)",
                    actionType: .write,
                    builder: builder,
                    onDone: { [weak self] updatedBuilder in
                        self?.showConfirm(builder: updatedBuilder, onComplete: onComplete)
                    },
                    onCancel: { onComplete(nil) }
                )
                showActionInputWithContext(writeCtx)
            },
            Button("Skip") { [weak self] in
                guard let self else { return }
                Application.requestStop()
                showConfirm(builder: builder, onComplete: onComplete)
            },
            Button("Cancel") {
                Application.requestStop()
                onComplete(nil)
            },
        ])
        let msg = Label("Add write actions to modify image file metadata directly?")
        msg.x = Pos.at(1)
        msg.y = Pos.at(1)
        msg.width = Dim.fill(1)
        dialog.addSubview(msg)
        Application.present(top: dialog)
    }

    func showConfirm(builder: RuleBuilder, onComplete: @escaping (Rule?) -> Void) {
        let result = builder.build()

        switch result {
        case let .failure(error):
            let dialog = Dialog(title: "Cannot Save", width: 60, height: 8, buttons: [
                Button("OK") {
                    Application.requestStop()
                    onComplete(nil)
                },
            ])
            let msg = Label(error.errorDescription ?? "Invalid rule")
            msg.x = Pos.at(1)
            msg.y = Pos.at(1)
            msg.width = Dim.fill(1)
            dialog.addSubview(msg)
            Application.present(top: dialog)

        case let .success(rule):
            let top = makeWizardToplevel()

            let win = WizardWindow("Confirm Rule")
            win.fill()
            top.addSubview(win)

            let matchLabel = Label("  Match: \(rule.match.field) ~ \(rule.match.pattern)")
            matchLabel.x = Pos.at(0)
            matchLabel.y = Pos.at(0)
            matchLabel.width = Dim.fill()
            win.addSubview(matchLabel)

            var yPos = 2
            let emitHeader = Label("  Emit actions:")
            emitHeader.x = Pos.at(0)
            emitHeader.y = Pos.at(yPos)
            win.addSubview(emitHeader)
            yPos += 1

            for emit in rule.emit {
                let desc = Self.describeEmit(emit)
                let lbl = Label("    \(desc)")
                lbl.x = Pos.at(0)
                lbl.y = Pos.at(yPos)
                lbl.width = Dim.fill()
                win.addSubview(lbl)
                yPos += 1
            }

            if !rule.write.isEmpty {
                yPos += 1
                let writeHeader = Label("  Write actions:")
                writeHeader.x = Pos.at(0)
                writeHeader.y = Pos.at(yPos)
                win.addSubview(writeHeader)
                yPos += 1

                for write in rule.write {
                    let desc = Self.describeEmit(write)
                    let lbl = Label("    \(desc)")
                    lbl.x = Pos.at(0)
                    lbl.y = Pos.at(yPos)
                    lbl.width = Dim.fill()
                    win.addSubview(lbl)
                    yPos += 1
                }
            }

            let footer = Label("  s save   c cancel")
            footer.x = Pos.at(0)
            footer.y = Pos.at(yPos + 2)
            footer.width = Dim.fill()
            win.addSubview(footer)

            win.onKey = { event in
                switch event.key {
                case .letter("s"):
                    Application.requestStop()
                    onComplete(rule)
                    return true
                case .letter("c"), .esc:
                    Application.requestStop()
                    onComplete(nil)
                    return true
                default:
                    return false
                }
            }

            Application.present(top: top)
        }
    }
}
