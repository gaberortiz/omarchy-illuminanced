import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
    id: root
    moduleName: "user.illuminanced"
    ipcTarget: "user.illuminanced"
    manageIpc: false

    property int brightnessPercent: 50
    property int pendingBrightnessPercent: 50
    property bool autoBrightnessEnabled: true
    property int sensorValue: 0
    property bool serviceRunning: false
    property bool brightnessAvailable: true
    property bool brightnessSetQueued: false

    readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
    readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

    property string focusSection: "brightness"
    property int selectedIndex: -1
    property bool cursorActive: false

    readonly property var visibleSections: ["brightness", "auto"]

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function sectionCount(section) { return 0 }
    function sectionIsSingleRow(section) { return true }
    function sectionFirstIndex(section) { return -1 }

    function moveCursor(delta) {
        var sections = visibleSections
        if (!sections || sections.length === 0) return
        var sIdx = sections.indexOf(focusSection)
        if (sIdx < 0) { focusSection = sections[0]; selectedIndex = -1; return }
        if (delta > 0 && sIdx < sections.length - 1) { focusSection = sections[sIdx + 1]; selectedIndex = -1 }
        else if (delta < 0 && sIdx > 0) { focusSection = sections[sIdx - 1]; selectedIndex = -1 }
    }

    function adjustBrightness(delta) {
        if (focusSection !== "brightness") return
        if (!brightnessAvailable) return
        setBrightness(root.brightnessPercent + delta)
    }

    function activateCursor() {
        if (focusSection === "auto") toggleAutoBrightness()
    }

    function clampCursor() {
        var sections = visibleSections
        if (!sections || !sections.length) return
        if (sections.indexOf(focusSection) < 0) { focusSection = sections[0]; selectedIndex = -1 }
    }

    function brightnessIpc(percent) {
        var value = Number(percent)
        root.setBrightness(value)
        return "got " + root.pendingBrightnessPercent
    }
    function autoIpc(enabled) {
        root.setAutoBrightness(enabled === "true" || enabled === true)
        return "auto " + (root.autoBrightnessEnabled ? "on" : "off")
    }
    function stateIpc() {
        return JSON.stringify({ brightness: root.brightnessPercent, autoBrightness: root.autoBrightnessEnabled, sensor: root.sensorValue, serviceRunning: root.serviceRunning, w: root.implicitWidth, h: root.implicitHeight, inBar: root.bar !== null && root.bar !== undefined, slotW: root.parent ? Math.round(root.parent.width) : -1, slotH: root.parent ? Math.round(root.parent.height) : -1 })
    }

    IpcHandler {
        target: "user.illuminanced"
        function brightness(percent: string): string { return root.brightnessIpc(percent) }
        function auto(enabled: string): string { return root.autoIpc(enabled) }
        function state(): string { return root.stateIpc() }
        function open() { root.open() }
        function close() { root.close() }
        function toggle() { root.toggle() }
        function show() { root.open() }
        function hide() { root.close() }
    }

    function setBrightness(value) {
        var percent = Math.max(1, Math.min(100, Math.round(value)))
        root.brightnessPercent = percent
        root.pendingBrightnessPercent = percent
        if (setBrightnessProc.running) { root.brightnessSetQueued = true; return }
        root.brightnessSetQueued = false
        setBrightnessProc.command = ["brightnessctl", "-d", "amdgpu_bl1", "set", percent + "%"]
        setBrightnessProc.running = true
    }

    function setAutoBrightness(enabled) {
        root.autoBrightnessEnabled = enabled
        var manualFile = "/tmp/user-autobright-manual"
        if (enabled) {
            // Remove manual override file to resume auto
            autoControlProc.command = ["rm", "-f", manualFile]
        } else {
            // Create manual override file to pause auto
            autoControlProc.command = ["touch", manualFile]
        }
        autoControlProc.running = true
    }

    function toggleAutoBrightness() { setAutoBrightness(!root.autoBrightnessEnabled) }

    // The daemon already polls the sensor and the service every second. It
    // publishes what it found, so the widget reads one small file instead of
    // spawning its own brightnessctl, systemctl and sensor probes. Quickshell's
    // FileView does not follow this file on change here, and re-reading it
    // returns cached text, so this is a bare cat of ~90 bytes rather than a
    // shell pipeline: one tiny process every couple of seconds.
    Process {
        id: statusProc
        command: ["cat", Quickshell.env("XDG_RUNTIME_DIR") + "/user-autobright-status.json"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyStatus(text)
        }
    }

    Timer {
        interval: 2000
        repeat: true
        running: true
        onTriggered: if (!statusProc.running) statusProc.running = true
    }

    function applyStatus(raw) {
        if (!raw) return
        var s
        try { s = JSON.parse(raw) } catch (e) { return }
        if (s.brightness === undefined) return
        root.brightnessPercent = s.brightness
        root.pendingBrightnessPercent = s.brightness
        root.sensorValue = s.sensor === undefined ? 0 : s.sensor
        root.autoBrightnessEnabled = s.auto === true
        root.serviceRunning = s.serviceRunning === true
    }

    Process { id: setBrightnessProc
        stdout: StdioCollector { waitForEnd: true }
        onRunningChanged: {
            if (!running && root.brightnessSetQueued) {
                root.setBrightness(root.pendingBrightnessPercent)
            }
        }
    }

    Process { id: autoControlProc
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
    }

    readonly property string barText: root.autoBrightnessEnabled ? "☀" + root.brightnessPercent + "%" : root.brightnessPercent + "%"

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.barText
        onPressed: function(b) { if (root.opened) root.close(); else root.open() }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(280))
        contentHeight: panel.fittedContentHeight(column.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: false
            onMoveRequested: function(dx, dy) {
                if (!root.cursorActive) { root.cursorActive = true; if (dy >= 0) return }
                if (dy !== 0) root.moveCursor(dy)
                if (dx !== 0) root.adjustBrightness(dx * 5)
            }
            onActivateRequested: { if (root.cursorActive) root.activateCursor() }
            onCloseRequested: root.close()
        }

        Column {
            id: column
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(12)

            Item {
                width: parent.width
                implicitHeight: Math.max(iconLabel.implicitHeight, labels.implicitHeight)
                Text {
                    id: iconLabel
                    text: root.autoBrightnessEnabled ? "󰇡" : "󰃠"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.display
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    id: labels
                    anchors.left: iconLabel.right
                    anchors.leftMargin: Style.space(14)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    Text {
                        text: "Auto Brightness"
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.title
                        font.bold: true
                    }
                    Text {
                        text: root.autoBrightnessEnabled ? "Sensor: " + root.sensorValue + " | Auto ON" : "Auto OFF - Manual control"
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                    }
                }
            }

            PanelSeparator { foreground: root.bar.foreground }

            Column {
                id: brightnessSection
                width: parent.width
                spacing: Style.space(8)
                Row {
                    width: parent.width
                    spacing: Style.space(10)
                    PanelSectionHeader { text: "BRIGHTNESS"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
                    Text { text: root.brightnessPercent + "%"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                }
                Slider {
                    id: brightnessSlider
                    width: parent.width
                    from: 1
                    to: 100
                    value: root.brightnessPercent
                    stepSize: 1
                    hoverEnabled: true
                    onValueChanged: { if (pressed) root.brightnessPercent = value }
                    onPressedChanged: { if (!pressed && root.brightnessPercent !== value) root.setBrightness(value) }
                    background: Rectangle { implicitHeight: Style.space(6); radius: Style.space(3); color: Qt.darker(root.bar.background, 1.2) }
                    contentItem: Rectangle { implicitHeight: Style.space(6); radius: Style.space(3); color: Color.accent; width: brightnessSlider.visualPosition * parent.width }
                    handle: Rectangle { width: Style.space(16); height: Style.space(16); radius: Style.space(8); color: root.bar.foreground; x: brightnessSlider.visualPosition * (parent.width - width); y: (parent.height - height) / 2; Behavior on x { NumberAnimation { duration: 50 } } }
                }
            }

            PanelSeparator { foreground: root.bar.foreground }

            Column {
                id: autoSection
                width: parent.width
                spacing: Style.space(10)
                Row {
                    width: parent.width
                    spacing: Style.space(10)
PanelSectionHeader {
                        text: "AUTO BRIGHTNESS"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                    }
                    ToggleSwitch {
                        id: autoSwitch
                        checked: root.autoBrightnessEnabled
                        busy: autoControlProc.running
                        hasCursor: root.cursorActive && root.focusSection === "auto"
                        foreground: root.bar.foreground
                        Layout.alignment: Qt.AlignVCenter
                        onToggled: root.toggleAutoBrightness()
                        onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "auto" } }
                        PanelToolTip {
                            visible: autoSwitch.containsMouse
                            text: root.autoBrightnessEnabled ? "Disable ambient light auto-brightness" : "Enable ambient light auto-brightness"
                            fontFamily: root.bar.fontFamily
                        }
                    }
                }
                Row {
                    width: parent.width
                    spacing: Style.space(10)
                    PanelSectionHeader { text: "SENSOR"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
                    Text { text: root.sensorValue + " lux (raw)"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
    }
}