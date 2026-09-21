import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "levonium.rss"
  ipcTarget: "levonium.rss"

  // Resolve paths from this file so the plugin works wherever it is installed.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")
  readonly property string statePath: root.dataHome + "/levonium-rss/state.json"

  property var feeds: []
  property var items: []
  property var unreadByFeed: ({})
  property int unreadTotal: 0

  property string view: "feeds" // "feeds" | "items" | "form"
  property string currentFeed: "" // "" = all feeds
  property string formMode: "add" // "add" | "edit"
  property string formId: ""
  property string formName: ""
  property string formUrl: ""
  property string formError: ""
  property bool busy: false
  property bool refreshing: false

  property bool confirmOpen: false
  property string confirmId: ""
  property string confirmName: ""


  // Keyboard/mouse cursor over the rows of the current view.
  //   feeds: [Mark all read (only if any feeds)] [feed...] [Add feed]
  //   items: [Mark all read] [item...]
  property int cursor: 0
  property bool keyNav: false
  readonly property var shownItems: root.view === "items" ? root.visibleItems() : []
  readonly property int feedBase: root.feeds.length > 0 ? 1 : 0
  readonly property int targetCount: root.view === "feeds" ? root.feedBase + root.feeds.length + 1
    : root.view === "items" ? 1 + root.shownItems.length : 0

  function feedName(id) {
    for (var i = 0; i < feeds.length; i++) if (feeds[i].id === id) return feeds[i].name
    return ""
  }

  function ago(ts) {
    var s = Math.max(0, Math.floor(Date.now() / 1000) - ts)
    if (s < 3600) return Math.max(1, Math.floor(s / 60)) + "m"
    if (s < 86400) return Math.floor(s / 3600) + "h"
    if (s < 86400 * 30) return Math.floor(s / 86400) + "d"
    return Math.floor(s / 86400 / 30) + "mo"
  }

  function visibleItems() {
    var out = []
    for (var i = 0; i < items.length; i++)
      if (items[i].feed === currentFeed) out.push(items[i])
    out.sort(function(a, b) { return b.date - a.date })
    return out
  }

  function applyState(text) {
    var s
    try { s = JSON.parse(text) } catch (e) { return }
    var counts = {}, total = 0
    for (var i = 0; i < s.items.length; i++) {
      if (!s.items[i].read) {
        counts[s.items[i].feed] = (counts[s.items[i].feed] || 0) + 1
        total++
      }
    }
    root.feeds = s.feeds
    root.items = s.items
    root.unreadByFeed = counts
    root.unreadTotal = total
    if (root.view === "items" && root.feedName(root.currentFeed) === "")
      root.showFeeds()
    if (root.cursor > root.targetCount - 1) root.cursor = Math.max(0, root.targetCount - 1)
  }

  // Each helper call gets its own Process; feeds.py serialises state writes
  // itself, so concurrent calls are safe.
  function run(args, done) {
    procComp.createObject(root, { command: ["python3", root.pluginDir + "/feeds.py"].concat(args), done: done || null })
  }

  function refresh() {
    if (root.refreshing) return
    root.refreshing = true
    root.run(["refresh"], function() { root.refreshing = false })
  }

  // Hidden text fields keep activeFocus when their view goes away, which
  // silently kills the key catcher. Always hand focus back after a view change.
  function focusKeys() { Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }

  function showFeeds() {
    var idx = root.feedBase
    for (var i = 0; i < feeds.length; i++) if (feeds[i].id === currentFeed) idx = root.feedBase + i
    root.view = "feeds"
    root.currentFeed = ""
    root.cursor = Math.min(idx, root.targetCount - 1)
    root.focusKeys()
  }

  function showItems(feedId) {
    root.currentFeed = feedId
    root.view = "items"
    root.cursor = Math.min(1, root.targetCount - 1)
    root.focusKeys()
  }

  function moveCursor(dy) {
    if (root.targetCount === 0) return
    root.keyNav = true
    root.cursor = Math.max(0, Math.min(root.targetCount - 1, root.cursor + dy))
  }

  function feedAtCursor() {
    var i = root.cursor - root.feedBase
    return root.view === "feeds" && i >= 0 && i < root.feeds.length ? root.feeds[i] : null
  }

  function itemAtCursor() {
    var i = root.cursor - 1
    return root.view === "items" && i >= 0 && i < root.shownItems.length ? root.shownItems[i] : null
  }

  function activateCursor() {
    if (root.view === "feeds") {
      var f = root.feedAtCursor()
      if (f) root.showItems(f.id)
      else if (root.feedBase === 1 && root.cursor === 0) root.markAllRead()
      else root.showForm("add", null)
    } else if (root.view === "items") {
      var it = root.itemAtCursor()
      if (it) root.openItem(it)
      else root.markAllRead()
    }
  }

  function ensureVisible(item) {
    var fl = scrollArea.contentItem
    var p = item.mapToItem(fl.contentItem, 0, 0)
    if (p.y < fl.contentY) fl.contentY = Math.max(0, p.y - Style.space(8))
    else if (p.y + item.height > fl.contentY + fl.height)
      fl.contentY = p.y + item.height - fl.height + Style.space(8)
  }

  function showForm(mode, feed) {
    root.formMode = mode
    root.formId = feed ? feed.id : ""
    root.formName = feed ? feed.name : ""
    root.formUrl = feed ? feed.url : ""
    root.formError = ""
    root.view = "form"
    Qt.callLater(function() { urlField.forceActiveFocus() })
  }

  function submitForm() {
    if (root.busy || root.formUrl.trim() === "") return
    root.busy = true
    root.formError = ""
    var args = root.formMode === "add"
      ? ["add", root.formUrl.trim(), root.formName.trim()]
      : ["edit", root.formId, root.formName.trim(), root.formUrl.trim()]
    root.run(args, function(out) {
      root.busy = false
      if (out.indexOf("error:") === 0) root.formError = out.replace(/^error:\s*/, "")
      else root.showFeeds()
    })
  }

  function requestRemove(feed) {
    root.confirmId = feed.id
    root.confirmName = feed.name
    root.confirmOpen = true
  }

  function performRemove() {
    root.confirmOpen = false
    root.run(["remove", root.confirmId])
  }

  function openItem(item) {
    if (item.link !== "") Quickshell.execDetached(["xdg-open", item.link])
    if (!item.read) root.run(["read", item.id])
  }

  // On the feed list this clears everything; inside a feed, just that feed.
  function markAllRead() {
    root.run(root.view === "items" ? ["read", "all", root.currentFeed] : ["read", "all"])
  }

  FileView {
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    // First run: no state file yet. A refresh seeds the default feed(s) and fetches them.
    onLoadFailed: root.refresh()
  }

  Component {
    id: procComp
    Process {
      id: p
      property var done: null
      running: true
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (p.done) p.done(text.trim())
          p.destroy()
        }
      }
    }
  }

  Timer {
    interval: 15000
    running: true
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: Math.max(5, root.setting("refreshIntervalMin", 30)) * 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (!root.opened) {
      root.confirmOpen = false
      if (root.view === "form") root.showFeeds()
    } else {
      if (root.view === "feeds") root.cursor = Math.min(root.feedBase, root.targetCount - 1)
      root.focusKeys()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf09e" // nf-fa-rss
    onPressed: function(b) { root.toggle() }

    Rectangle {
      visible: root.unreadTotal > 0
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(-2)
      anchors.topMargin: Style.space(-1)
      width: Math.max(height, badgeText.implicitWidth + Style.space(6))
      height: Style.space(13)
      radius: height / 2
      color: Color.accent

      Text {
        textFormat: Text.PlainText
        id: badgeText
        anchors.centerIn: parent
        text: root.unreadTotal > 99 ? "99+" : root.unreadTotal
        color: Color.background
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption - 1
        font.bold: true
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.view === "form"
      onCloseRequested: function() {
        if (root.confirmOpen) root.confirmOpen = false
        else if (root.view !== "feeds") root.showFeeds()
        else root.close()
      }
      onMoveRequested: function(dx, dy) {
        if (root.confirmOpen) {
          if (dx !== 0) confirm.selectedIndex = confirm.selectedIndex === 0 ? 1 : 0
        } else if (dy !== 0) {
          root.moveCursor(dy)
        }
      }
      onActivateRequested: function() {
        if (root.confirmOpen) {
          if (confirm.selectedIndex === 0) root.confirmOpen = false
          else root.performRemove()
        } else {
          root.activateCursor()
        }
      }
      onDeleteRequested: function() {
        var f = root.feedAtCursor()
        if (f && !root.confirmOpen) root.requestRemove(f)
      }
      onTabRequested: function(direction) { if (!root.confirmOpen) root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.confirmOpen) return
        if (t === "r" || t === "R") root.refresh()
        else if ((t === "a" || t === "A") && root.view === "feeds") root.showForm("add", null)
        else if ((t === "e" || t === "E") && root.feedAtCursor()) root.showForm("edit", root.feedAtCursor())
        else if ((t === "m" || t === "M") && root.view !== "form") root.markAllRead()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: root.view === "items" ? root.feedName(root.currentFeed)
              : root.view === "form" ? (root.formMode === "add" ? "Add feed" : "Edit feed") : "Feeds"
            meta: root.feeds.length === 0 ? "No feeds yet"
              : root.unreadTotal + " unread · " + root.feeds.length + (root.feeds.length === 1 ? " feed" : " feeds")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\uf09e" // nf-fa-rss
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)
                PanelActionButton {
                  visible: root.view !== "form"
                  iconText: "\uf021" // nf-fa-refresh
                  tooltipText: root.refreshing ? "Refreshing…" : "Refresh all (r)"
                  opacity: root.refreshing ? 0.5 : 1.0
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.refresh()
                }
                PanelActionButton {
                  visible: root.view !== "feeds"
                  iconText: "\uf060" // nf-fa-arrow_left
                  tooltipText: "Back"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.showFeeds()
                }
              }
            }
          }

          // ---- Feeds list ----
          Column {
            width: parent.width
            visible: root.view === "feeds"
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              visible: root.feeds.length === 0
              width: parent.width
              text: "Add a feed to get started (press a)"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Button {
              width: parent.width
              visible: root.feeds.length > 0
              text: "Mark all read (m)"
              bordered: true
              enabled: root.unreadTotal > 0
              opacity: enabled ? 1.0 : 0.5
              hasCursor: root.view === "feeds" && root.cursor === 0
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onHovered: function(h) { if (h) { root.keyNav = false; root.cursor = 0 } }
              onClicked: root.markAllRead()
            }

            Repeater {
              model: root.feeds
              delegate: FeedRow {
                required property var modelData
                required property int index
                width: parent.width
                feed: modelData
                idx: root.feedBase + index
              }
            }

            Button {
              width: parent.width
              text: "Add feed (a)"
              iconText: "\uf067" // nf-fa-plus
              bordered: true
              hasCursor: root.view === "feeds" && root.cursor === root.feedBase + root.feeds.length
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onHovered: function(h) { if (h) { root.keyNav = false; root.cursor = root.feedBase + root.feeds.length } }
              onClicked: root.showForm("add", null)
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "j/k move · enter open · e edit · x remove · r refresh"
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ---- Items list ----
          Column {
            width: parent.width
            visible: root.view === "items"
            spacing: Style.space(8)

            Button {
              width: parent.width
              text: "Mark all read (m)"
              bordered: true
              enabled: (root.unreadByFeed[root.currentFeed] || 0) > 0
              opacity: enabled ? 1.0 : 0.5
              hasCursor: root.view === "items" && root.cursor === 0
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onHovered: function(h) { if (h) { root.keyNav = false; root.cursor = 0 } }
              onClicked: root.markAllRead()
            }

            Text {
              textFormat: Text.PlainText
              visible: root.shownItems.length === 0
              width: parent.width
              text: "Nothing here yet"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.shownItems
              delegate: ItemRow {
                required property var modelData
                required property int index
                width: parent.width
                item: modelData
                idx: index + 1
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "j/k move · enter open · m mark all read · esc back"
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ---- Add / edit form ----
          Column {
            width: parent.width
            visible: root.view === "form"
            spacing: Style.space(10)

            TextField {
              id: urlField
              width: parent.width
              placeholderText: "Feed or site URL"
              text: root.formUrl
              foreground: root.bar.foreground
              onTextEdited: root.formUrl = text
              onAccepted: root.submitForm()
              Keys.onEscapePressed: function(e) { root.showFeeds(); e.accepted = true }
            }

            TextField {
              width: parent.width
              placeholderText: "Name (optional)"
              text: root.formName
              foreground: root.bar.foreground
              onTextEdited: root.formName = text
              onAccepted: root.submitForm()
              Keys.onEscapePressed: function(e) { root.showFeeds(); e.accepted = true }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.formError !== ""
              width: parent.width
              text: root.formError
              color: root.bar.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Cancel"
                bordered: true
                focusable: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                Keys.onEscapePressed: function(e) { root.showFeeds(); e.accepted = true }
                onClicked: root.showFeeds()
              }
              Button {
                width: (parent.width - parent.spacing) / 2
                text: root.busy ? "Checking…" : (root.formMode === "add" ? "Add" : "Save")
                bordered: true
                enabled: !root.busy && root.formUrl.trim() !== ""
                opacity: enabled ? 1.0 : 0.5
                focusable: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                Keys.onEscapePressed: function(e) { root.showFeeds(); e.accepted = true }
                onClicked: root.submitForm()
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: "Remove " + root.confirmName + "?"
        confirmText: "Remove"
        background: Color.popups.background
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        cornerRadius: Style.cornerRadius
        onCanceled: root.confirmOpen = false
        onConfirmed: root.performRemove()
      }
    }
  }

  component FeedRow: CursorSurface {
    id: row
    property var feed
    property int idx: 0
    readonly property int unread: root.unreadByFeed[feed.id] || 0

    implicitHeight: Style.space(50)
    foreground: root.bar.foreground
    hasCursor: root.view === "feeds" && root.cursor === row.idx
    color: hasCursor ? fill : Style.normalFillFor(root.bar.foreground, Color.accent)
    onHasCursorChanged: if (hasCursor && root.keyNav) root.ensureVisible(row)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.keyNav = false; root.cursor = row.idx }
      onClicked: root.showItems(row.feed.id)
    }

    Column {
      anchors.left: parent.left
      anchors.right: actions.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.feed.name
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.unread > 0
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.feed.error !== "" ? row.feed.error : row.feed.url
        color: row.feed.error !== "" ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        visible: row.unread > 0
        anchors.verticalCenter: parent.verticalCenter
        text: row.unread
        color: Color.accent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        rightPadding: Style.space(4)
      }
      PanelActionButton {
        iconText: "\uf040" // nf-fa-pencil
        tooltipText: "Edit feed"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.showForm("edit", row.feed)
      }
      PanelActionButton {
        iconText: "\uf1f8" // nf-fa-trash
        tooltipText: "Remove feed"
        foreground: root.bar.foreground
        hoverColor: root.bar.urgent
        fontFamily: root.bar.fontFamily
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.requestRemove(row.feed)
      }
    }
  }

  component ItemRow: CursorSurface {
    id: row
    property var item
    property int idx: 0

    implicitHeight: Math.max(Style.space(50), textCol.implicitHeight + Style.space(16))
    foreground: root.bar.foreground
    hasCursor: root.view === "items" && root.cursor === row.idx
    color: hasCursor ? fill : Style.normalFillFor(root.bar.foreground, Color.accent)
    opacity: row.item.read ? 0.6 : 1.0
    onHasCursorChanged: if (hasCursor && root.keyNav) root.ensureVisible(row)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.keyNav = false; root.cursor = row.idx }
      onClicked: root.openItem(row.item)
    }

    Column {
      id: textCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.item.title
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: !row.item.read
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.ago(row.item.date)
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        visible: row.item.summary !== ""
        width: parent.width
        text: row.item.summary
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }
  }
}
