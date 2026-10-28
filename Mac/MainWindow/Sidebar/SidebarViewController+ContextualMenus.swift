//
//  SidebarViewController+ContextualMenus.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 1/28/18.
//  Copyright © 2018 Ranchero Software. All rights reserved.
//

import AppKit
import Articles
import Account
import RSCore
import UserNotifications

extension Notification.Name {
	public static let DidUpdateFeedPreferencesFromContextMenu = Notification.Name(rawValue: "DidUpdateFeedPreferencesFromContextMenu")
}

extension SidebarViewController {

	func menu(for objects: [Any]?) -> NSMenu? {

		guard let objects = objects, objects.count > 0 else {
			return menuForNoSelection()
		}

		if objects.count > 1 {
			return menuForMultipleObjects(objects)
		}

		let object = objects.first!

		switch object {
		case is Feed:
			return menuForFeed(object as! Feed)
		case is Folder:
			return menuForFolder(object as! Folder)
		case is PseudoFeed:
			return menuForSmartFeed(object as! PseudoFeed)
		default:
			return nil
		}
	}
}

// MARK: Contextual Menu Actions

extension SidebarViewController {

	@objc func translateFeedFromContextualMenu(_ sender: Any?) {
		guard let item = sender as? NSMenuItem, let feed = item.representedObject as? Feed else {
			return
		}
		AITranslationService.shared.translateFeed(feed)
		AITranslationQueueWindow.shared.present(feedKey: feed.accountID + ":" + feed.feedID)
	}

	@objc func deleteFeedArticlesByDate(_ sender: Any?) {
		guard let item = sender as? NSMenuItem, let feed = item.representedObject as? Feed,
			let account = feed.account, let window = view.window else { return }
		let start = NSDatePicker()
		let end = NSDatePicker()
		for picker in [start, end] {
			picker.datePickerStyle = .textFieldAndStepper
			picker.datePickerElements = [.yearMonthDay]
		}
		start.dateValue = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
		end.dateValue = Date()
		let dates = NSStackView(views: [start, NSTextField(labelWithString: "至"), end])
		dates.spacing = 8
		dates.setFrameSize(dates.fittingSize)
		let alert = NSAlert()
		alert.messageText = "删除此订阅源的文章"
		alert.informativeText = "选择发布日期范围，包含起止日期。删除后这些文章不会因刷新再次出现。"
		alert.accessoryView = dates
		alert.addButton(withTitle: "查找文章")
		alert.addButton(withTitle: "取消")
		alert.beginSheetModal(for: window) { response in
			guard response == .alertFirstButtonReturn else { return }
			let first = Calendar.current.startOfDay(for: start.dateValue)
			let last = Calendar.current.startOfDay(for: end.dateValue)
			guard first <= last, let exclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: last) else {
				let error = NSAlert()
				error.messageText = "开始日期不能晚于结束日期"
				error.beginSheetModal(for: window)
				return
			}
			Task { @MainActor in
				let all = await account.fetchArticlesAsync(.feed(feed))
				let matches = Set(all.filter { article in
					guard let date = article.datePublished else { return false }
					return date >= first && date < exclusiveEnd
				})
				let confirm = NSAlert()
				confirm.messageText = matches.isEmpty ? "没有找到符合日期的文章" : "删除 \(matches.count) 篇文章？"
				confirm.informativeText = "包含已收藏的文章；删除后无法在应用中撤销。没有发布日期的文章不会被删除。"
				if !matches.isEmpty { confirm.addButton(withTitle: "删除") }
				confirm.addButton(withTitle: matches.isEmpty ? "好" : "取消")
				confirm.beginSheetModal(for: window) { result in
					guard !matches.isEmpty, result == .alertFirstButtonReturn else { return }
					Task { await account.deleteLocalArticles(matches, from: feed) }
				}
			}
		}
	}

	@objc func setFeedArticleCutoff(_ sender: Any?) {
		guard let item = sender as? NSMenuItem, let feed = item.representedObject as? Feed,
			let account = feed.account, let window = view.window else { return }
		let existing = account.articleCutoff(for: feed)
		let enabled = NSButton(checkboxWithTitle: "不接收此日期之前发布的文章", target: nil, action: nil)
		enabled.state = existing == nil ? .off : .on
		let picker = NSDatePicker()
		picker.datePickerStyle = .textFieldAndStepper
		picker.datePickerElements = [.yearMonthDay]
		picker.dateValue = existing ?? Date()
		let stack = NSStackView(views: [enabled, picker])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 10
		stack.setFrameSize(stack.fittingSize)
		let alert = NSAlert()
		alert.messageText = "设置接收文章的起始日期"
		alert.informativeText = "此设置只影响以后抓取的文章；没有发布日期的文章仍会接收。"
		alert.accessoryView = stack
		alert.addButton(withTitle: "保存")
		alert.addButton(withTitle: "取消")
		alert.beginSheetModal(for: window) { response in
			guard response == .alertFirstButtonReturn else { return }
			account.setArticleCutoff(enabled.state == .on ? Calendar.current.startOfDay(for: picker.dateValue) : nil, for: feed)
		}
	}

	@objc func openHomePageFromContextualMenu(_ sender: Any?) {

		guard let menuItem = sender as? NSMenuItem, let urlString = menuItem.representedObject as? String else {
			return
		}
		Browser.open(urlString, inBackground: false)
	}

	@objc func copyURLFromContextualMenu(_ sender: Any?) {

		guard let menuItem = sender as? NSMenuItem, let urlString = menuItem.representedObject as? String else {
			return
		}
		URLPasteboardWriter.write(urlString: urlString, to: NSPasteboard.general)
	}

	@objc func markObjectsReadFromContextualMenu(_ sender: Any?) {

		guard let menuItem = sender as? NSMenuItem, let objects = menuItem.representedObject as? [Any] else {
			return
		}

		let articles = unreadArticles(for: objects)
		guard let undoManager = undoManager, let markReadCommand = MarkStatusCommand(initialArticles: Array(articles), markingRead: true, undoManager: undoManager) else {
			return
		}
		runCommand(markReadCommand)
	}

	@objc func deleteFromContextualMenu(_ sender: Any?) {
		guard let menuItem = sender as? NSMenuItem, let objects = menuItem.representedObject as? [AnyObject] else {
			return
		}

		let nodes = objects.compactMap { treeController.nodeInTreeRepresentingObject($0) }

		let alert = SidebarDeleteItemsAlert.build(nodes)
		alert.beginSheetModal(for: view.window!) { [weak self] result in
			if result == NSApplication.ModalResponse.alertFirstButtonReturn {
				self?.deleteNodes(nodes)
			}
		}
	}

	@objc func renameFromContextualMenu(_ sender: Any?) {

		guard let window = view.window, let menuItem = sender as? NSMenuItem, let object = menuItem.representedObject as? DisplayNameProvider, object is Feed || object is Folder else {
			return
		}

		renameWindowController = RenameWindowController(originalTitle: object.nameForDisplay, representedObject: object, delegate: self)
		guard let renameSheet = renameWindowController?.window else {
			return
		}
		window.beginSheet(renameSheet)
	}

	@objc func toggleNotificationsFromContextMenu(_ sender: Any?) {
		guard let item = sender as? NSMenuItem,
			  let feed = item.representedObject as? Feed else {
			return
		}
		UNUserNotificationCenter.current().getNotificationSettings { (settings) in
			if settings.authorizationStatus == .denied {
				self.showNotificationsNotEnabledAlert()
			} else if settings.authorizationStatus == .authorized {
				DispatchQueue.main.async {
					feed.newArticleNotificationsEnabled.toggle()
					NotificationCenter.default.post(Notification(name: .DidUpdateFeedPreferencesFromContextMenu))
				}
			} else {
				UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert]) { granted, _ in
					if granted {
						DispatchQueue.main.async {
							feed.newArticleNotificationsEnabled.toggle()
							NotificationCenter.default.post(Notification(name: .DidUpdateFeedPreferencesFromContextMenu))
							NSApplication.shared.registerForRemoteNotifications()
						}
					} else {
						self.showNotificationsNotEnabledAlert()
					}
				}
			}
		}
	}

	@objc func toggleArticleExtractorFromContextMenu(_ sender: Any?) {
		guard let item = sender as? NSMenuItem,
			  let feed = item.representedObject as? Feed else {
			return
		}
		feed.readerViewAlwaysEnabled.toggle()
		NotificationCenter.default.post(Notification(name: .DidUpdateFeedPreferencesFromContextMenu))
	}

	nonisolated func showNotificationsNotEnabledAlert() {
		DispatchQueue.main.async {
			let alert = NSAlert()
			alert.messageText = NSLocalizedString("Notifications are not enabled", comment: "Notifications are not enabled.")
			alert.informativeText = NSLocalizedString("You can enable NetNewsWire notifications in System Preferences.", comment: "Notifications are not enabled.")
			alert.addButton(withTitle: NSLocalizedString("Open System Preferences", comment: "Open System Preferences"))
			alert.addButton(withTitle: NSLocalizedString("Dismiss", comment: "Dismiss"))
			let userChoice = alert.runModal()
			if userChoice == .alertFirstButtonReturn {
				let config = NSWorkspace.OpenConfiguration()
				config.activates = true
				// If System Preferences is already open, and no delay is provided here, then it appears in the foreground and immediately disappears.
				DispatchQueue.main.asyncAfter(wallDeadline: .now() + 0.2, execute: {
					NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!, configuration: config)
				})
			}
		}
	}

}

extension SidebarViewController: RenameWindowControllerDelegate {

	func renameWindowController(_ windowController: RenameWindowController, didRenameObject object: Any, withNewName name: String) {

		if let feed = object as? Feed {
			feed.rename(to: name) { result in
				switch result {
				case .success:
					break
				case .failure(let error):
					NSApplication.shared.presentError(error)
				}
			}
		} else if let folder = object as? Folder {
			folder.rename(to: name) { result in
				switch result {
				case .success:
					break
				case .failure(let error):
					NSApplication.shared.presentError(error)
				}
			}
		}
	}
}

// MARK: Build Contextual Menus

private extension SidebarViewController {

	func menuForNoSelection() -> NSMenu {

		let menu = NSMenu(title: "")

		menu.addItem(withTitle: NSLocalizedString("New Feed", comment: "Command"), action: #selector(AppDelegate.showAddFeedWindow(_:)), keyEquivalent: "")
		menu.addItem(withTitle: NSLocalizedString("New Folder", comment: "Command"), action: #selector(AppDelegate.showAddFolderWindow(_:)), keyEquivalent: "")

		return menu
	}

	func menuForFeed(_ feed: Feed) -> NSMenu? {

		let menu = NSMenu(title: "")

		if feed.unreadCount > 0 {
			menu.addItem(markAllReadMenuItem([feed]))
			menu.addItem(NSMenuItem.separator())
		}

		if let homePageURL = feed.homePageURL, URL(string: homePageURL) != nil {
			let item = menuItem(NSLocalizedString("Open Home Page", comment: "Command"), #selector(openHomePageFromContextualMenu(_:)), homePageURL)
			menu.addItem(item)
			menu.addItem(NSMenuItem.separator())
		}

		let copyFeedURLItem = menuItem(NSLocalizedString("Copy Feed URL", comment: "Command"), #selector(copyURLFromContextualMenu(_:)), feed.url)
		menu.addItem(copyFeedURLItem)

		if let homePageURL = feed.homePageURL {
			let item = menuItem(NSLocalizedString("Copy Home Page URL", comment: "Command"), #selector(copyURLFromContextualMenu(_:)), homePageURL)
			menu.addItem(item)
		}
		menu.addItem(NSMenuItem.separator())

		let notificationText = feed.notificationDisplayName.capitalized
		menu.addItem(menuItem("翻译此订阅源", #selector(translateFeedFromContextualMenu(_:)), feed))
		if feed.account?.type == .onMyMac {
			menu.addItem(menuItem("设置接收文章的起始日期…", #selector(setFeedArticleCutoff(_:)), feed))
			menu.addItem(menuItem("按日期删除文章…", #selector(deleteFeedArticlesByDate(_:)), feed))
		}
		menu.addItem(NSMenuItem.separator())

		let notificationMenuItem = menuItem(notificationText, #selector(toggleNotificationsFromContextMenu(_:)), feed)
		notificationMenuItem.state = feed.newArticleNotificationsEnabled ? .on : .off
		menu.addItem(notificationMenuItem)

		let articleExtractorText = NSLocalizedString("Always Use Reader View", comment: "Always Use Reader View")
		let articleExtractorMenuItem = menuItem(articleExtractorText, #selector(toggleArticleExtractorFromContextMenu(_:)), feed)

		articleExtractorMenuItem.state = feed.readerViewAlwaysEnabled ? .on : .off
		menu.addItem(articleExtractorMenuItem)

		menu.addItem(NSMenuItem.separator())

		menu.addItem(renameMenuItem(feed))
		menu.addItem(deleteMenuItem([feed]))

		return menu
	}

	func menuForFolder(_ folder: Folder) -> NSMenu? {

		let menu = NSMenu(title: "")

		if folder.unreadCount > 0 {
			menu.addItem(markAllReadMenuItem([folder]))
			menu.addItem(NSMenuItem.separator())
		}

		menu.addItem(renameMenuItem(folder))
		menu.addItem(deleteMenuItem([folder]))

		return menu.numberOfItems > 0 ? menu : nil
	}

	func menuForSmartFeed(_ smartFeed: PseudoFeed) -> NSMenu? {

		let menu = NSMenu(title: "")

		if smartFeed.unreadCount > 0 {
			menu.addItem(markAllReadMenuItem([smartFeed]))
		}
		return menu.numberOfItems > 0 ? menu : nil
	}

	func menuForMultipleObjects(_ objects: [Any]) -> NSMenu? {

		let menu = NSMenu(title: "")

		if anyObjectInArrayHasNonZeroUnreadCount(objects) {
			menu.addItem(markAllReadMenuItem(objects))
		}

		if allObjectsAreFeedsAndOrFolders(objects) {
			menu.addSeparatorIfNeeded()
			menu.addItem(deleteMenuItem(objects))
		}

		return menu.numberOfItems > 0 ? menu : nil
	}

	func markAllReadMenuItem(_ objects: [Any]) -> NSMenuItem {

		return menuItem(NSLocalizedString("Mark All as Read", comment: "Command"), #selector(markObjectsReadFromContextualMenu(_:)), objects)
	}

	func deleteMenuItem(_ objects: [Any]) -> NSMenuItem {

		return menuItem(NSLocalizedString("Delete", comment: "Delete button"), #selector(deleteFromContextualMenu(_:)), objects)
	}

	func renameMenuItem(_ object: Any) -> NSMenuItem {

		return menuItem(NSLocalizedString("Rename", comment: "Command"), #selector(renameFromContextualMenu(_:)), object)
	}

	func anyObjectInArrayHasNonZeroUnreadCount(_ objects: [Any]) -> Bool {

		for object in objects {
			if let unreadCountProvider = object as? UnreadCountProvider {
				if unreadCountProvider.unreadCount > 0 {
					return true
				}
			}
		}
		return false
	}

	func allObjectsAreFeedsAndOrFolders(_ objects: [Any]) -> Bool {

		for object in objects {
			if !objectIsFeedOrFolder(object) {
				return false
			}
		}
		return true
	}

	func objectIsFeedOrFolder(_ object: Any) -> Bool {

		return object is Feed || object is Folder
	}

	func menuItem(_ title: String, _ action: Selector, _ representedObject: Any) -> NSMenuItem {

		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.representedObject = representedObject
		item.target = self
		return item
	}

	func unreadArticles(for objects: [Any]) -> Set<Article> {

		var articles = Set<Article>()
		for object in objects {
			if let articleFetcher = object as? ArticleFetcher {
				let unreadArticles = articleFetcher.fetchUnreadArticles()
				articles.formUnion(unreadArticles)
			}
		}
		return articles
	}
}
