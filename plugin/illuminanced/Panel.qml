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

    // Live calibration, mirrored from the daemon's config so the editor and the
    // process actually applying the curve never disagree.
    property int curveDark: 3
    property int curveLight: 48
    property real curveGamma: 0.5
    property int curveMin: 5
    property int curveMax: 100
    property string curveSaveMsg: ""
    property bool curveOpen: false
    readonly property string daemonPath: Quickshell.env("HOME") + "/.local/bin/user-autobright.py"
    readonly property int curveRange: Math.max(curveLight, 60)

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
        return JSON.stringify({ brightness: root.brightnessPercent, autoBrightness: root.autoBrightnessEnabled, sensor: root.sensorValue, serviceRunning: root.serviceRunning, w: root.implicitWidth, h: root.implicitHeight, inBar: root.bar !== null && root.bar !== undefined, slotW: root.parent ? Math.round(root.parent.width) : -1, slotH: root.parent ? Math.round(root.parent.height) : -1, curve: { dark: root.curveDark, light: root.curveLight, gamma: root.curveGamma, min: root.curveMin, max: root.curveMax }, curveOpen: root.curveOpen, sensorMapped: root.curvePercent(root.sensorValue) })
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
        if (s.curve) {
            root.curveDark = s.curve.dark
            root.curveLight = s.curve.light
            root.curveGamma = s.curve.gamma
            root.curveMin = s.curve.min
            root.curveMax = s.curve.max
        }
    }

    // Applied live while dragging so the plot tracks the slider, then written
    // once on release. The daemon picks the file up on its next poll.
    function previewCurve(key, value) {
        if (key === "dark") root.curveDark = Math.round(value)
        else if (key === "light") root.curveLight = Math.round(value)
        else if (key === "gamma") root.curveGamma = Math.round(value * 100) / 100
    }

    // The daemon reads its config once at startup and used to need a restart to
    // see an edit, so writes go through its own --set mode. It validates the
    // whole file and refuses an unusable curve, which is why the panel never
    // has to reason about whether dark < light before sending.
    function writeCurve(key, value) {
        curveProc.command = ["bash", "-c", root.daemonPath + " --set " + key + "=" + value + " 2>&1"]
        curveProc.running = true
    }

    function saveCurve() {
        writeCurve("dark", root.curveDark)
        writeCurve("light", root.curveLight)
        writeCurve("gamma", root.curveGamma)
    }

    // Same mapping as the daemon's interpolate_brightness, so the preview is
    // the real curve rather than an approximation that drifts from it.
    function curvePercent(raw) {
        if (raw <= root.curveDark) return root.curveMin
        if (raw >= root.curveLight) return root.curveMax
        var ratio = (raw - root.curveDark) / (root.curveLight - root.curveDark)
        if (root.curveGamma !== 1) ratio = Math.pow(ratio, root.curveGamma)
        return Math.round(root.curveMin + ratio * (root.curveMax - root.curveMin))
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

    Process { id: curveProc
        stdout: StdioCollector { waitForEnd: true }
        onExited: { root.curveSaveMsg = "Saved"; curveMsgTimer.restart() }
    }

    Timer { id: curveMsgTimer; interval: 1600; onTriggered: root.curveSaveMsg = "" }

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

            PanelSeparator { foreground: root.bar.foreground }

            // Collapsible curve editor. The header is always visible so the
            // panel does not open to a wall of sliders; everything below it is
            // hidden until asked for.
            Column {
                id: curveSection
                width: parent.width
                spacing: Style.space(10)

                Item {
                    width: parent.width
                    implicitHeight: Math.max(curveTitle.implicitHeight, curveChevron.implicitHeight)
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Style.space(-4)
                        radius: Style.cornerRadius
                        color: curveMouse.containsMouse ? root.selectedFill : "transparent"
                    }
                    PanelSectionHeader {
                        id: curveTitle
                        text: "RESPONSE CURVE"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)
                        Text {
                            text: root.curveSaveMsg
                            visible: text !== ""
                            color: Qt.darker(root.bar.foreground, 1.4)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            id: curveChevron
                            text: ">"
                            color: root.bar.foreground
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.subtitle
                            font.bold: true
                            rotation: root.curveOpen ? 90 : 0
                            Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        }
                    }
                    MouseArea {
                        id: curveMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.curveOpen = !root.curveOpen
                    }
                }

                Column {
                    width: parent.width
                    spacing: Style.space(12)
                    visible: root.curveOpen
                    height: visible ? implicitHeight : 0

                    // Live plot of raw sensor counts against target percent,
                    // with the current reading marked, so a slider drag shows
                    // the effect before it is saved.
                    Canvas {
                        id: curvePlot
                        width: parent.width
                        height: Style.space(120)

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            ctx.fillStyle = Qt.darker(root.bar.background, 1.2)
                            ctx.fillRect(0, 0, width, height)

                            var span = root.curveRange
                            var toX = function(v) { return (v / span) * width }
                            var toY = function(p) { return height - (p / 100) * height }

                            ctx.strokeStyle = Qt.darker(root.bar.foreground, 1.9)
                            ctx.lineWidth = 1
                            ctx.beginPath()
                            ctx.moveTo(0, toY(0)); ctx.lineTo(width, toY(0))
                            ctx.moveTo(0, toY(100)); ctx.lineTo(width, toY(100))
                            ctx.stroke()

                            ctx.strokeStyle = Color.accent
                            ctx.lineWidth = 2
                            ctx.beginPath()
                            var started = false
                            for (var raw = 0; raw <= span; raw += 1) {
                                var px = toX(raw)
                                var py = toY(root.curvePercent(raw))
                                if (!started) { ctx.moveTo(px, py); started = true }
                                else ctx.lineTo(px, py)
                            }
                            ctx.stroke()

                            var mx = toX(root.sensorValue)
                            if (root.sensorValue <= span) {
                                ctx.strokeStyle = root.bar.foreground
                                ctx.lineWidth = 1
                                ctx.beginPath()
                                ctx.moveTo(mx, 0); ctx.lineTo(mx, height)
                                ctx.stroke()
                                ctx.fillStyle = root.bar.foreground
                                ctx.beginPath()
                                ctx.arc(mx, toY(root.curvePercent(root.sensorValue)), 3, 0, Math.PI * 2)
                                ctx.fill()
                            }
                        }
                        // Repaint when anything the curve depends on moves.
                        Connections {
                            target: root
                            function onCurveDarkChanged() { curvePlot.requestPaint() }
                            function onCurveLightChanged() { curvePlot.requestPaint() }
                            function onCurveGammaChanged() { curvePlot.requestPaint() }
                            function onCurveMinChanged() { curvePlot.requestPaint() }
                            function onCurveMaxChanged() { curvePlot.requestPaint() }
                            function onSensorValueChanged() { curvePlot.requestPaint() }
                        }
                    }

                    Text {
                        width: parent.width
                        text: "now: raw " + root.sensorValue + " -> " + root.curvePercent(root.sensorValue) + "%"
                        color: Qt.darker(root.bar.foreground, 1.3)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                    }

                    Repeater {
                        model: [
                            { label: "DARK", key: "dark", from: 0, to: Math.max(1, root.curveLight - 1), step: 1 },
                            { label: "LIGHT", key: "light", from: Math.min(root.curveLight + 1, 999), to: 999, step: 1 },
                            { label: "GAMMA", key: "gamma", from: 0.1, to: 3.0, step: 0.05 }
                        ]

                        Column {
                            id: curveRow
                            required property var modelData
                            width: curveSection.width
                            spacing: Style.space(4)

                            readonly property real currentValue: modelData.key === "gamma"
                                ? root.curveGamma
                                : (modelData.key === "dark" ? root.curveDark : root.curveLight)

                            Row {
                                width: parent.width
                                spacing: Style.space(10)
                                PanelSectionHeader {
                                    text: curveRow.modelData.label
                                    foreground: root.bar.foreground
                                    fontFamily: root.bar.fontFamily
                                }
                                Text {
                                    text: curveRow.modelData.key === "gamma"
                                        ? Number(curveRow.currentValue).toFixed(2)
                                        : String(Math.round(curveRow.currentValue))
                                    color: root.bar.foreground
                                    font.family: root.bar.fontFamily
                                    font.pixelSize: Style.font.caption
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Slider {
                                id: curveSlider
                                width: parent.width
                                from: curveRow.modelData.from
                                to: curveRow.modelData.to
                                stepSize: curveRow.modelData.step
                                value: curveRow.currentValue
                                live: true
                                onValueChanged: if (pressed) root.previewCurve(curveRow.modelData.key, value)
                                onPressedChanged: if (!pressed) root.saveCurve()
                                background: Rectangle { implicitHeight: Style.space(4); radius: Style.space(2); color: Qt.darker(root.bar.background, 1.2) }
                                contentItem: Rectangle { implicitHeight: Style.space(4); radius: Style.space(2); color: Color.accent; width: curveSlider.visualPosition * parent.width }
                                handle: Rectangle { width: Style.space(12); height: Style.space(12); radius: Style.space(6); color: root.bar.foreground; x: curveSlider.visualPosition * (parent.width - width); y: (parent.height - height) / 2 }
                            }
                        }
                    }
                }
            }
        }
    }
}