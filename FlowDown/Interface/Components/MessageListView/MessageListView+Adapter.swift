//
//  Created by ktiays on 2025/1/29.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import AlertController
import ListViewKit
import Litext
import MarkdownView
import RichEditor
import Storage
import UIKit

private extension MessageListView {
    enum RowType {
        case userContent
        case userAttachment
        case reasoningContent
        case aiContent
        case hint
        case webSearch
        case activityReporting
        case toolCallHint
    }
}

extension MessageListView: ListViewAdapter {
    func listView(_: ListViewKit.ListView, rowKindFor item: ItemType, at _: Int) -> RowKind {
        guard let entry = item as? Entry else {
            assertionFailure("Invalid item type")
            return RowType.userContent
        }

        return switch entry {
        case .userContent: RowType.userContent
        case .userAttachment: RowType.userAttachment
        case .aiContent: RowType.aiContent
        case .webSearchContent: RowType.webSearch
        case .hint: RowType.hint
        case .activityReporting: RowType.activityReporting
        case .reasoningContent: RowType.reasoningContent
        case .toolCallStatus: RowType.toolCallHint
        }
    }

    func listViewMakeRow(for kind: RowKind) -> ListViewKit.ListRowView {
        guard let rowType = kind as? RowType else {
            assertionFailure("Invalid row kind")
            return .init()
        }

        let view = switch rowType {
        case .userContent:
            UserMessageView()
        case .userAttachment:
            UserAttachmentView()
        case .reasoningContent:
            ReasoningContentView()
        case .aiContent:
            AiMessageView()
        case .hint:
            HintMessageView()
        case .webSearch:
            WebSearchStateView()
        case .activityReporting:
            ActivityReportingView()
        case .toolCallHint:
            ToolHintView()
        }
        view.theme = theme
        return view
    }

    func listView(_ list: ListViewKit.ListView, heightFor item: ItemType, at _: Int) -> CGFloat {
        let listRowInsets = MessageListView.listRowInsets
        let containerWidth = max(0, list.bounds.width - listRowInsets.horizontal)
        if containerWidth == 0 {
            return 0
        }

        guard let entry = item as? Entry else {
            assertionFailure("Invalid item type")
            return 0
        }

        let bottomInset = listRowInsets.bottom
        let contentHeight: CGFloat = {
            switch entry {
            case let .userContent(_, message):
                let content = message.content
                let attributedContent = NSAttributedString(string: content, attributes: [
                    .font: theme.fonts.body,
                ])
                let availableWidth = UserMessageView.availableTextWidth(for: containerWidth)
                return boundingSize(with: availableWidth, for: attributedContent).height + UserMessageView.textPadding * 2
            case .userAttachment:
                return AttachmentsBar.itemHeight
            case let .reasoningContent(_, message):
                let attributedContent = NSAttributedString(string: message.content, attributes: [
                    .font: theme.fonts.footnote,
                    .paragraphStyle: ReasoningContentView.paragraphStyle,
                ])
                if message.isRevealed {
                    return boundingSize(
                        with: containerWidth - 16,
                        for: attributedContent
                    ).height + ReasoningContentView.spacing + ReasoningContentView.revealedTileHeight + 2
                } else {
                    return ReasoningContentView.unrevealedTileHeight
                }
            case let .aiContent(_, message):
                markdownViewForSizeCalculation.theme = theme
                let package = markdownPackageCache.package(for: message, theme: theme)
                markdownViewForSizeCalculation.setMarkdownManually(package)
                let boundingSize = markdownViewForSizeCalculation.boundingSize(for: containerWidth)
                return ceil(boundingSize.height)
            case .hint:
                return ceil(theme.fonts.footnote.lineHeight + 16)
            case .webSearchContent:
                return WebSearchStateView.intrinsicHeight(withLabelFont: theme.fonts.body)
            case let .activityReporting(content):
                let contentHeight = boundingSize(with: .infinity, for: .init(string: content, attributes: [
                    .font: theme.fonts.body,
                ])).height
                return max(contentHeight, ActivityReportingView.loadingSymbolSize.height + 16)
            case .toolCallStatus:
                return theme.fonts.body.lineHeight + 20
            }
        }()
        return contentHeight + bottomInset
    }

    func listView(_ listView: ListViewKit.ListView, configureRowView rowView: ListViewKit.ListRowView, for item: ItemType, at index: Int) {
        guard let entry = item as? Entry else {
            assertionFailure("Invalid item type")
            return
        }

        if let rowView = rowView as? MessageListRowView {
            rowView.handleContextMenu = { pointInRowContentView in
                let pointInListView = listView.convert(pointInRowContentView, from: rowView.contentView)
                self.processContextMenu(listView, anchor: pointInListView, for: item, at: index)
            }
        }

        if let userMessageView = rowView as? UserMessageView {
            if case let .userContent(_, message) = entry {
                userMessageView.text = message.content
            } else { assertionFailure() }
        } else if let attachmentView = rowView as? UserAttachmentView {
            if case let .userAttachment(_, attachments) = entry {
                attachmentView.update(with: attachments)
            } else { assertionFailure() }
        } else if let aiMessageView = rowView as? AiMessageView {
            if case let .aiContent(_, message) = entry {
                aiMessageView.theme = theme
                let package = markdownPackageCache.package(for: message, theme: theme)
                aiMessageView.markdownView.setMarkdown(package)
                aiMessageView.linkTapHandler = { [weak self] link, range, touchLocation in
                    self?.handleLinkTapped(link, in: range, at: aiMessageView.convert(touchLocation, to: self))
                }
                aiMessageView.codePreviewHandler = { [weak self] lang, code in
                    self?.detailDetailController(code: code, language: lang, title: String(localized: "Code Viewer"))
                }
            } else { assertionFailure() }
        } else if let hintMessageView = rowView as? HintMessageView {
            if case let .hint(_, content) = entry {
                hintMessageView.text = content
            } else { assertionFailure() }
        } else if let stateView = rowView as? WebSearchStateView {
            if case let .webSearchContent(webSearchPhase) = entry {
                stateView.update(with: webSearchPhase)
            }
        } else if let activityReportingView = rowView as? ActivityReportingView {
            if case let .activityReporting(content) = entry {
                activityReportingView.text = content
            }
        } else if let reasoningContentView = rowView as? ReasoningContentView {
            if case let .reasoningContent(_, message) = entry {
                reasoningContentView.isRevealed = message.isRevealed
                reasoningContentView.isThinking = message.isThinking
                reasoningContentView.thinkingDuration = message.thinkingDuration
                reasoningContentView.text = message.content
                reasoningContentView.thinkingTileTapHandler = { [unowned self] newValue in
                    guard let thinkingMessage = session.messages.filter({
                        $0.id == -message.id
                    }).first else {
                        return
                    }
                    thinkingMessage.isThinkingFold = !newValue
                    updateList()
                    session.save()
                }
            }
        } else if let toolHintView = rowView as? ToolHintView {
            if case let .toolCallStatus(status) = entry {
                let state: ToolHintView.State = switch status.state {
                case 1:
                    .suceeded
                default:
                    .failed
                }
                toolHintView.toolName = status.name
                toolHintView.state = state
                toolHintView.text = status.message
                toolHintView.clickHandler = { [weak self] in
                    let viewer = TextViewerController(editable: false)
                    viewer.title = String(localized: "Text Content")
                    viewer.text = status.message
                    #if targetEnvironment(macCatalyst)
                        let nav = UINavigationController(rootViewController: viewer)
                        nav.view.backgroundColor = .background
                        let holder = AlertBaseController(
                            rootViewController: nav,
                            preferredWidth: 555,
                            preferredHeight: 555
                        )
                        holder.shouldDismissWhenTappedAround = true
                        holder.shouldDismissWhenEscapeKeyPressed = true
                    #else
                        let holder = UINavigationController(rootViewController: viewer)
                        holder.preferredContentSize = .init(width: 555, height: 555 - holder.navigationBar.frame.height)
                        holder.modalTransitionStyle = .coverVertical
                        holder.modalPresentationStyle = .formSheet
                        holder.view.backgroundColor = .background
                    #endif
                    self?.parentViewController?.present(holder, animated: true)
                }
            }
        }
    }

    private func boundingSize(with width: CGFloat, for attributedString: NSAttributedString) -> CGSize {
        labelForSizeCalculation.preferredMaxLayoutWidth = width
        labelForSizeCalculation.attributedText = attributedString
        let contentSize = labelForSizeCalculation.intrinsicContentSize
        return .init(width: ceil(contentSize.width), height: ceil(contentSize.height))
    }

    private func hasActivatedEventOnLabel(listView: ListViewKit.ListView, location: CGPoint) -> Bool {
        var lookup: [UIView] = listView.subviews
        while !lookup.isEmpty {
            let view = lookup.removeFirst()
            lookup.append(contentsOf: view.subviews)
            if let label = view as? LTXLabel {
                if label.selectionRange != nil {
                    let location = label.convert(location, from: listView)
                    if label.isLocationInSelection(location: location) {
                        print("[*] event is activate on \(label)")
                        return true
                    }
                    label.clearSelection()
                }
            }
        }
        print("[*] no event, returning false")
        return false
    }

    private func processContextMenu(
        _ listView: ListViewKit.ListView,
        anchor point: CGPoint,
        for item: ItemType,
        at index: Int,
    ) {
        let hasActivateEvent = hasActivatedEventOnLabel(listView: listView, location: point)
        print("[*] context menu checking event \(hasActivateEvent)")
        guard !hasActivateEvent else { return }
        guard let view = listView.rowView(at: index) else { return }

        var isHandled = false
        defer {
            if isHandled {
                UIView.animate(withDuration: 0.15) {
                    view.alpha = 0.5
                } completion: { _ in
                    UIView.animate(withDuration: 0.5, delay: 0.25) {
                        view.alpha = 1
                    }
                }
            }
        }

        print("[*] item \(item) is presenting context menu at \(point) for index \(index)")
        guard let entry = item as? Entry else {
            assertionFailure("Invalid item type")
            return
        }

        switch entry {
        // MARK: - 用户消息

        case let .userContent(msgID, messageRepresentation):
            let menu = menu(
                for: msgID,
                representation: messageRepresentation,
                isReasoningContent: false,
                touchLocation: point,
                referenceView: view
            )
            listView.present(menu: menu, anchorPoint: point)
            isHandled = true
            return

        // MARK: - 推理内容

        case let .reasoningContent(msgID, messageRepresentation):
            let menu = menu(
                for: msgID,
                representation: messageRepresentation,
                isReasoningContent: true,
                touchLocation: point,
                referenceView: view
            )
            listView.present(menu: menu, anchorPoint: point)
            isHandled = true
            return

        // MARK: - 助手消息

        case let .aiContent(msgID, messageRepresentation):
            let menu = menu(
                for: msgID,
                representation: messageRepresentation,
                isReasoningContent: false,
                touchLocation: point,
                referenceView: view
            )
            listView.present(menu: menu, anchorPoint: point)
            isHandled = true
            return

        // MARK: - 活动状态

        case .hint, .activityReporting, .webSearchContent, .userAttachment, .toolCallStatus:
            return
        }
    }

    func menu(
        for messageIdentifier: Message.ID,
        representation: MessageRepresentation,
        isReasoningContent: Bool,
        touchLocation: CGPoint,
        referenceView: UIView
    ) -> UIMenu {
        UIMenu(title: String(localized: "Message"), children: [
            UIMenu(title: String(localized: "Operations"), options: [.displayInline], children: [
                { () -> UIAction? in
                    guard let message = session.message(for: messageIdentifier),
                          message.role == .user
                    else { return nil }
                    guard let editor = self.nearestEditor() else { return nil }
                    return UIAction(title: String(localized: "Redo"), image: .init(systemName: "arrow.clockwise")) { _ in
                        let attachments: [RichEditorView.Object.Attachment] = self.session
                            .attachments(for: messageIdentifier)
                            .compactMap {
                                guard let type: RichEditorView.Object.Attachment.AttachmentType = .init(rawValue: $0.type) else {
                                    return nil
                                }
                                return RichEditorView.Object.Attachment(
                                    id: .init(),
                                    type: type,
                                    name: $0.name,
                                    previewImage: $0.previewImageData,
                                    imageRepresentation: $0.imageRepresentation,
                                    textRepresentation: $0.representedDocument,
                                    storageSuffix: $0.storageSuffix
                                )
                            }
                        editor.refill(withText: message.document, attachments: attachments)
                        self.session.deleteCurrentAndAfter(messageIdentifier: messageIdentifier)
                        DispatchQueue.main.async { editor.focus() }
                    }
                }(),
                { () -> UIAction? in
                    guard let message = session.message(for: messageIdentifier),
                          message.role == .assistant,
                          session.nearestUserMessage(beforeOrEqual: messageIdentifier) != nil
                    else { return nil }
                    return UIAction(title: String(localized: "Retry"), image: .init(systemName: "arrow.clockwise")) { [weak self] _ in
                        guard let self else { return }
                        session.retry(byClearAfter: messageIdentifier, currentMessageListView: self)
                    }
                }(),
            ].compactMap(\.self)),
            UIMenu(title: String(localized: "Message"), options: [.displayInline], children: [
                UIAction(title: String(localized: "Copy"), image: .init(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = representation.content
                    Indicator.present(
                        title: String(localized: "Copied"),
                        preset: .done,
                        haptic: .success,
                        referencingView: self
                    )
                },
                UIAction(title: String(localized: "View Raw"), image: .init(systemName: "eye")) { [weak self] _ in
                    self?.detailDetailController(
                        code: .init(string: representation.content),
                        language: "markdown",
                        title: String(localized: "Raw Content")
                    )
                },
            ].compactMap(\.self)),
            UIMenu(title: String(localized: "Rewrite"), image: .init(systemName: "arrow.uturn.left"), options: [], children: [
                RewriteAction.allCases.map { action in
                    UIAction(title: action.title, image: action.icon) { [weak self] _ in
                        guard let self else { return }
                        action.send(to: session, message: messageIdentifier, bindView: self)
                    }
                },
            ].flatMap(\.self).compactMap(\.self)),
            UIMenu(title: String(localized: "More"), image: .init(systemName: "ellipsis.circle"), children: [
                UIMenu(title: String(localized: "More"), options: [.displayInline], children: [
                    UIAction(title: String(localized: "Copy as Image"), image: .init(systemName: "text.below.photo")) { _ in
                        let render = UIGraphicsImageRenderer(bounds: referenceView.bounds)
                        let image = render.image { ctx in
                            referenceView.layer.render(in: ctx.cgContext)
                        }
                        UIPasteboard.general.image = image
                        Indicator.present(
                            title: String(localized: "Copied"),
                            preset: .done,
                            haptic: .success,
                            referencingView: self
                        )
                    },
                ]),
                UIMenu(options: [.displayInline], children: [
                    UIAction(title: String(localized: "Edit"), image: .init(systemName: "pencil")) { [weak self] _ in
                        let viewer = self?.detailDetailController(
                            code: .init(string: representation.content),
                            language: "markdown",
                            title: String(localized: "Edit")
                        )
                        guard let viewer = viewer as? CodeEditorController else {
                            assertionFailure()
                            return
                        }
                        viewer.collectEditedContent { [weak self] text in
                            guard let self else { return }
                            print("[*] edited \(messageIdentifier) content: \(text)")
                            if isReasoningContent {
                                session?.update(messageIdentifier: messageIdentifier, reasoningContent: text)
                            } else {
                                session?.update(messageIdentifier: messageIdentifier, content: text)
                            }
                        }
                    },
                    UIAction(title: String(localized: "Share"), image: .init(systemName: "doc.on.doc")) { [weak self] _ in
                        guard let self else { return }
                        let shareSheet = UIActivityViewController(activityItems: [representation.content], applicationActivities: nil)
                        shareSheet.popoverPresentationController?.sourceView = self
                        shareSheet.popoverPresentationController?.sourceRect = .init(
                            origin: .init(x: touchLocation.x - 4, y: touchLocation.y - 4),
                            size: .init(width: 8, height: 8)
                        )
                        parentViewController?.present(shareSheet, animated: true)
                    },
                ]),
                UIMenu(options: [.displayInline], children: [
                    UIAction(title: String(localized: "Delete"), image: .init(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        if isReasoningContent {
                            self?.session.update(messageIdentifier: messageIdentifier, reasoningContent: "")
                        } else {
                            self?.session.delete(messageIdentifier: messageIdentifier)
                        }
                    },
                    UIAction(title: String(localized: "Delete w/ After"), image: .init(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        self?.session?.deleteCurrentAndAfter(messageIdentifier: messageIdentifier)
                    },
                ]),
            ]),
        ])
    }

    @discardableResult
    func detailDetailController(code: NSAttributedString, language: String?, title: String) -> UIViewController {
        let controller: UIViewController

        if language?.lowercased() == "html" {
            controller = HTMLPreviewController(content: code.string)
        } else {
            controller = CodeEditorController(language: language, text: code.string)
            controller.title = title
        }

        #if targetEnvironment(macCatalyst)
            let nav = UINavigationController(rootViewController: controller)
            nav.view.backgroundColor = .background
            let holder = AlertBaseController(
                rootViewController: nav,
                preferredWidth: 555,
                preferredHeight: 555
            )
            holder.shouldDismissWhenTappedAround = true
            holder.shouldDismissWhenEscapeKeyPressed = true
        #else
            let holder = UINavigationController(rootViewController: controller)
            holder.preferredContentSize = .init(width: 555, height: 555 - holder.navigationBar.frame.height)
            holder.modalTransitionStyle = .coverVertical
            holder.modalPresentationStyle = .formSheet
            holder.view.backgroundColor = .background
        #endif
        parentViewController?.present(holder, animated: true)
        return controller
    }
}

private extension UIView {
    func nearestEditor() -> RichEditorView? {
        var views = window?.subviews ?? []
        var index = 0
        repeat {
            let view = views[index]
            if let editor = view as? RichEditorView {
                return editor
            }
            views.append(contentsOf: view.subviews)
            index += 1
        } while index < views.count
        return nil
    }
}
