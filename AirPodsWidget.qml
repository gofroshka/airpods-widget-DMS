import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.Common
import qs.Widgets
import qs.Services
import qs.Modules.Plugins
import qs.DCommon.Widgets as Material

// AirPods widget for DankMaterialShell.
//
// This is the controller: it polls the LibrePods bridge for live state, exposes
// that state as reactive properties, and provides the control functions used by
// the bar pill, the popout and the Control Center tile.
PluginComponent {
    id: root

    // Keep polling while hidden so reconnecting brings the bar widget back.
    visible: root.connected

    property var popoutService: null

    // ---- shared live state -------------------------------------------------
    // The widget is instantiated once per surface (bar pill, popout, CC tile, CC
    // detail) and each instance runs independently. To keep every surface in sync
    // instantly, we don't keep per-instance state.
    // Instead every instance reads from, and writes to, ONE shared blob in
    // PluginService.globalVars (a reactive global singleton shared across all
    // instances). Writing it re-evaluates the bindings below in every instance.
    //
    // We key by a constant, not pluginId, because the CC detail instance has an
    // empty pluginId (see DetailHost note below) - but PluginService itself is
    // always reachable via qs.Services regardless of the injected pluginService.
    readonly property string storeId: "airpods_state"

    readonly property var shared: {
        var p = PluginService.globalVars[storeId]
        return (p && p.state) ? p.state : ({})
    }

    // Optimistic locks, keyed by field name: { mode: { value, until } }. Stored in
    // the shared blob too, so every instance's poll reconciler respects them (any
    // instance may be the one that polls). A lock says "the user just set this field
    // - ignore contradicting hardware reads until the read confirms the value or the
    // lock expires". This kills the new→old→new flicker: after a click, LibrePods'
    // tray toggle-state lags ~1-2s, so an in-flight poll reads the OLD mode and would
    // otherwise clobber the optimistic value before refreshSoon reads the settled one.
    readonly property var locks: {
        var p = PluginService.globalVars[storeId]
        return (p && p.locks) ? p.locks : ({})
    }
    // Safety-net ceiling. Normal case clears earlier: the confirming refreshSoon
    // (2.5s) reads the settled value and releases the lock. The timeout only matters
    // if the command silently failed and the value never changes.
    readonly property int lockMs: 4000

    // Every field is a binding onto the shared blob → all instances stay in sync.
    readonly property bool connected: shared.connected === true
    readonly property string model: shared.model || "buds"   // "buds" | "headset"
    readonly property bool isHeadset: model === "headset"
    readonly property string deviceIcon: isHeadset ? "headphones" : "earbuds"
    readonly property int batLeft: shared.left !== undefined ? shared.left : -1
    readonly property int batRight: shared.right !== undefined ? shared.right : -1
    readonly property int batCase: shared.case !== undefined ? shared.case : -1
    readonly property int batHeadset: shared.headset !== undefined ? shared.headset : -1
    readonly property string mode: shared.mode || "unknown"  // off | transparency | adaptive | anc | unknown
    readonly property bool conversation: shared.conversation === true
    readonly property bool earDetection: shared.earDetection === true
    readonly property string deviceName: shared.deviceName || "AirPods Pro 2"
    readonly property bool ready: shared.ready === true       // first poll completed

    // ---- static metadata ---------------------------------------------------
    readonly property var modeInfo: ({
            "off": { icon: "block", label: "Off" },
            "transparency": { icon: "noise_aware", label: "Transparency" },
            "adaptive": { icon: "auto_mode", label: "Adaptive" },
            "anc": { icon: "noise_control_on", label: "Noise Cancellation" },
            "unknown": { icon: "earbuds", label: "-" }
        })
    readonly property var modeOrder: isHeadset ? ["off", "transparency", "anc"] : ["off", "transparency", "adaptive", "anc"]

    readonly property string modeLabel: (modeInfo[mode] || modeInfo["unknown"]).label
    readonly property string modeIcon: (modeInfo[mode] || modeInfo["unknown"]).icon

    // Lowest available battery level, used for the compact bar/CC readouts.
    readonly property int lowestLevel: {
        if (model === "headset")
            return batHeadset
        var vals = []
        if (batLeft >= 0)
            vals.push(batLeft)
        if (batRight >= 0)
            vals.push(batRight)
        return vals.length ? Math.min.apply(Math, vals) : -1
    }

    // The bridge script path. We prefer pluginService.getPluginPath(), but that
    // requires a live pluginService AND a real pluginId - and the Control Center
    // detail is rendered on a throwaway instance created via
    // `pluginComponent.createObject(null)` (see DMS DetailHost.qml), i.e. with NO
    // pluginService and an empty pluginId. So we fall back to resolving the script
    // relative to this QML file's own location, which always works regardless of
    // how the instance was created. That lets every surface (bar popout, CC tile,
    // CC detail) poll and control on its own.
    readonly property string scriptPath: {
        var base = (pluginService && pluginId) ? pluginService.getPluginPath(pluginId) : ""
        if (base)
            return base + "/scripts/librepods-bridge.sh"
        // Strip the file:// scheme and any ?t= cache-buster query.
        return Qt.resolvedUrl("scripts/librepods-bridge.sh").toString().replace(/^file:\/\//, "").replace(/\?.*$/, "")
    }
    readonly property int pollInterval: (pluginData && pluginData.pollInterval) ? parseInt(pluginData.pollInterval) : 5

    // Proc.runCommand is a global singleton that keys its debouncer + callback by
    // this id. The widget is instantiated multiple times (bar popout, CC tile, CC
    // detail) and they poll concurrently, so a shared id would make instances
    // overwrite each other's callbacks - only one would ever update. Give every
    // instance a unique id namespace.
    readonly property string procTag: "airpods_" + Math.floor(Math.random() * 1e9)

    // ---- shared store writers ----------------------------------------------
    // Publish a fresh poll result. Before writing we reconcile against any active
    // optimistic locks: a locked field that the poll now agrees with is confirmed
    // (lock released); one the poll still disagrees with is either held at the
    // optimistic value (lock live) or, once expired, allowed through as hardware
    // truth (lock released). We dedupe so idle polling doesn't churn bindings.
    function publishState(st) {
        var now = Date.now()
        var curLocks = locks
        var out = Object.assign({}, st)
        var nextLocks = null // cloned lazily, only if a lock changes
        for (var f in curLocks) {
            var lock = curLocks[f]
            if (!lock)
                continue
            if (st[f] === lock.value) {
                // Hardware caught up → confirmed, release the lock.
                if (!nextLocks)
                    nextLocks = Object.assign({}, curLocks)
                delete nextLocks[f]
            } else if (now < lock.until) {
                // Still contradicting and within the window → hold optimistic value.
                out[f] = lock.value
            } else {
                // Timed out → accept hardware truth and release the lock.
                if (!nextLocks)
                    nextLocks = Object.assign({}, curLocks)
                delete nextLocks[f]
            }
        }
        if (!sameState(shared, out))
            PluginService.setGlobalVar(storeId, "state", out)
        if (nextLocks)
            PluginService.setGlobalVar(storeId, "locks", nextLocks)
    }

    // Merge a partial update (used by the poll's error path) into the shared blob,
    // preserving every other field. Does not touch locks.
    function patchState(patch) {
        PluginService.setGlobalVar(storeId, "state", Object.assign({}, shared, patch))
    }

    // Optimistic control write: set a field instantly across all instances AND lock
    // it, so no in-flight/next poll can flip it back until it confirms or expires.
    function optimisticSet(field, value) {
        var st = Object.assign({}, shared)
        st[field] = value
        var lk = Object.assign({}, locks)
        lk[field] = { value: value, until: Date.now() + lockMs }
        PluginService.setGlobalVar(storeId, "state", st)
        PluginService.setGlobalVar(storeId, "locks", lk)
    }

    function sameState(a, b) {
        var keys = ["ready", "connected", "model", "left", "right", "case", "headset", "mode", "conversation", "earDetection", "deviceName"]
        for (var i = 0; i < keys.length; i++) {
            if (a[keys[i]] !== b[keys[i]])
                return false
        }
        return true
    }

    // ---- data plumbing -----------------------------------------------------
    function refresh() {
        if (!scriptPath)
            return
        Proc.runCommand(procTag + "_status", ["bash", scriptPath, "status"], function (out, code) {
            // The callback can fire after the plugin has been reloaded/destroyed,
            // in which case touching `root` throws; guard the whole body.
            try {
                if (code !== 0 || !out) {
                    root.patchState({ ready: true, connected: false })
                    return
                }
                var s = JSON.parse(out.trim())
                var num = function (v) {
                    return (typeof v === "number") ? v : -1
                }
                root.publishState({
                    ready: true,
                    connected: !!s.connected,
                    model: s.model || "buds",
                    left: num(s.left),
                    right: num(s.right),
                    case: num(s.case),
                    headset: num(s.headset),
                    mode: s.mode || "unknown",
                    conversation: !!s.conversation,
                    earDetection: !!s.earDetection,
                    deviceName: s.deviceName || root.deviceName
                })
            } catch (e) {
                if (root)
                    root.patchState({ ready: true, connected: false })
            }
        }, 0, 6000)
    }

    // ---- control -----------------------------------------------------------
    function setNoise(id) {
        if (!scriptPath || modeOrder.indexOf(id) < 0)
            return
        root.optimisticSet("mode", id) // instantly synced + locked against stale polls
        Proc.runCommand(procTag + "_noise", ["bash", scriptPath, "noise", id], function () {
            refreshSoon.restart()
        }, 0, 6000)
    }

    function cycleAncTransparency() {
        setNoise(mode === "anc" ? "transparency" : "anc")
    }

    // Conversation Awareness can be read from LibrePods but not toggled through
    // any external interface it offers (no CLI/socket command for it, and the tray
    // menu ignores DBus activation events). We show the live state read-only and
    // point the user at the LibrePods app to change it.
    function conversationInfo() {
        ToastService?.showInfo("Conversation Awareness is set in the LibrePods app")
    }

    function setEarDetection(on) {
        if (!scriptPath)
            return
        root.optimisticSet("earDetection", on) // instantly synced + locked against stale polls
        Proc.runCommand(procTag + "_eardetection", ["bash", scriptPath, "eardetection", on ? "on" : "off"], function () {
            ToastService?.showInfo("Ear detection " + (on ? "enabled" : "disabled") + " - reconnect AirPods to apply")
        }, 0, 6000)
    }

    function rename(name) {
        if (!scriptPath || !name || !name.length)
            return
        root.optimisticSet("deviceName", name) // instantly synced + locked against stale polls
        Proc.runCommand(procTag + "_rename", ["bash", scriptPath, "rename", name], function () {
            ToastService?.showInfo("Renamed - reconnect AirPods to apply")
            refreshSoon.restart()
        }, 0, 6000)
    }

    Component.onCompleted: refresh()

    Timer {
        interval: root.pollInterval * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // Re-poll after a control command to confirm the optimistic state. LibrePods'
    // tray toggle-state lags the real mode change by ~1-2s, so we wait long enough
    // for it to settle rather than reading a stale value and flickering back.
    Timer {
        id: refreshSoon
        interval: 2500
        repeat: false
        onTriggered: root.refresh()
    }

    // =======================================================================
    //  Inline UI components (shared by the popout and the Control Center)
    // =======================================================================

    // Circular battery indicator: a track ring, a coloured progress arc, and the
    // level (or a dash / bolt) in the centre.
    component BatteryRing: Item {
        id: ring

        property int level: -1               // 0..100, or -1 when unavailable
        property bool charging: false
        property string centerIcon: ""
        property color ringColor: Theme.primary
        property color trackColor: Theme.withAlpha(Theme.surfaceText, 0.14)

        readonly property bool available: level >= 0
        readonly property real strokeW: 5
        readonly property real ringRadius: (width - strokeW) / 2

        implicitWidth: 58
        implicitHeight: 58

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            asynchronous: false

            ShapePath {
                strokeColor: ring.trackColor
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.width / 2
                    centerY: ring.height / 2
                    radiusX: ring.ringRadius
                    radiusY: ring.ringRadius
                    startAngle: -90
                    sweepAngle: 360
                }
            }

            ShapePath {
                strokeColor: ring.ringColor
                strokeWidth: ring.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.width / 2
                    centerY: ring.height / 2
                    radiusX: ring.ringRadius
                    radiusY: ring.ringRadius
                    startAngle: -90
                    sweepAngle: ring.available ? 360 * Math.max(0, Math.min(100, ring.level)) / 100 : 0

                    Behavior on sweepAngle {
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
        }

        Item {
            anchors.centerIn: parent
            width: parent.width * 0.72
            height: width

            DankIcon {
                visible: ring.charging && ring.available
                anchors.centerIn: parent
                name: "bolt"
                filled: true
                size: Theme.iconSize - 6
                color: ring.ringColor
            }

            DankIcon {
                visible: ring.centerIcon.length > 0 && !ring.charging
                anchors.centerIn: parent
                name: ring.centerIcon
                size: ring.width * 0.4
                color: ring.ringColor
            }

            StyledText {
                visible: !ring.centerIcon && !(ring.charging && ring.available)
                anchors.centerIn: parent
                text: ring.available ? ring.level : "-"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.DemiBold
                color: ring.available ? Theme.surfaceText : Theme.surfaceVariantText
            }
        }
    }

    // A settings-style row: leading icon, title + subtitle, trailing switch.
    component ToggleRow: Item {
        id: rowItem

        property string icon: ""
        property string title: ""
        property string subtitle: ""
        property bool checked: false

        signal toggled(bool value)

        implicitHeight: 56

        Row {
            anchors.left: parent.left
            anchors.right: toggle.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingXS
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingM

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: rowItem.icon
                filled: rowItem.checked && rowItem.enabled
                size: Theme.iconSize - 2
                color: rowItem.checked && rowItem.enabled ? Theme.primary : Theme.surfaceVariantText
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - (Theme.iconSize - 2) - Theme.spacingM
                spacing: 1

                StyledText {
                    text: rowItem.title
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    width: parent.width
                }

                StyledText {
                    text: rowItem.subtitle
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    width: parent.width
                }
            }
        }

        DankToggle {
            id: toggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            hideText: true
            checked: rowItem.checked
            enabled: rowItem.enabled
            onToggled: value => rowItem.toggled(value)
        }
    }

    // The full AirPods panel body: header, battery rings, noise control, toggles
    // and footer. `controller` is this AirPodsWidget (passed in, because inline
    // components cannot reach the file-scope `root` id directly).
    component PanelBody: Column {
        id: panel

        property var controller
        property bool renaming: false

        spacing: Theme.spacingM

        // ---- header --------------------------------------------------------
        Item {
            width: parent.width
            height: 48

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Theme.spacingS
                spacing: Theme.spacingM

                Rectangle {
                    width: 46
                    height: 46
                    radius: Theme.cornerRadiusL
                    color: Theme.primaryContainer
                    anchors.verticalCenter: parent.verticalCenter

                    DankIcon {
                        anchors.centerIn: parent
                        name: panel.controller.deviceIcon
                        filled: true
                        size: Theme.iconSizeLarge - 6
                        color: Theme.onPrimaryContainer
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 46 - Theme.spacingM
                    spacing: 2

                    Loader {
                        active: true
                        width: parent.width
                        sourceComponent: StyledText {
                            text: panel.controller.deviceName
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                            width: parent ? parent.width : implicitWidth
                        }
                    }

                }
            }
        }

        // ---- battery -------------------------------------------------------
        Row {
            width: parent.width
            spacing: Theme.spacingS

            Repeater {
                model: panel.controller.model === "headset" ? [] : [
                    { name: "Left", level: panel.controller.batLeft, charging: false },
                    { name: "Right", level: panel.controller.batRight, charging: false },
                    { name: "Case", level: panel.controller.batCase, charging: panel.controller.batCase >= 100 }
                ]

                delegate: Rectangle {
                    width: (parent.width - Theme.spacingS * 2) / 3
                    height: 108
                    radius: Theme.cornerRadiusL
                    color: Theme.surfaceContainerHigh

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        BatteryRing {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 56
                            height: 56
                            level: modelData.level
                            charging: modelData.charging
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.name
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }
                    }
                }
            }

            Loader {
                active: panel.controller.model === "headset"
                width: parent.width
                sourceComponent: Rectangle {
                    id: headsetBattery
                    readonly property int level: panel.controller.batHeadset
                    readonly property bool available: level >= 0
                    readonly property color accent: available && level <= 20 ? Theme.error : Theme.primary
                    height: 144
                    radius: Theme.cornerRadiusL
                    color: Theme.surfaceContainerHigh

                    Material.DMaterialShape {
                        id: batteryCookie
                        anchors.centerIn: parent
                        width: 120
                        height: 120
                        shape: "cookie12"
                        color: headsetBattery.accent
                        trackColor: Theme.surfaceContainerHighest
                        fillProgress: headsetBattery.available ? Math.max(0, Math.min(100, headsetBattery.level)) / 100 : 0

                        Behavior on fillProgress {
                            NumberAnimation {
                                duration: Theme.shortDuration
                                easing.type: Easing.OutCubic
                            }
                        }

                        Material.DMaterialShape {
                            anchors.fill: parent
                            anchors.margins: 6
                            shape: batteryCookie.shape
                            color: Theme.surfaceContainerHigh
                        }

                        StyledText {
                            anchors.centerIn: parent
                            text: headsetBattery.available ? headsetBattery.level + "%" : "—"
                            font.pixelSize: Theme.fontSizeXXLarge
                            font.weight: Font.Medium
                            color: Theme.onSurface
                        }
                    }
                }
            }
        }

        // ---- noise control -------------------------------------------------
        Column {
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                text: "Noise control"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold
                color: Theme.surfaceVariantText
            }

            Material.DButtonGroup {
                width: parent.width
                fillWidth: true
                size: "small"
                checkEnabled: false
                enabled: panel.controller.connected
                model: panel.controller.modeOrder.map(function (mode) {
                    return { text: mode === "anc" ? "ANC" : panel.controller.modeInfo[mode].label }
                })
                currentIndex: panel.controller.modeOrder.indexOf(panel.controller.mode)
                onSelectionChanged: (index, selected) => {
                    if (selected)
                        panel.controller.setNoise(panel.controller.modeOrder[index])
                }
            }
        }

        // ---- toggles -------------------------------------------------------
        Column {
            width: parent.width
            spacing: 0

            ToggleRow {
                visible: !panel.controller.isHeadset
                width: parent.width
                icon: "record_voice_over"
                title: "Conversation Awareness"
                subtitle: "Lowers volume when you speak · set in LibrePods"
                checked: panel.controller.conversation
                enabled: panel.controller.connected
                onToggled: panel.controller.conversationInfo()
            }

            Rectangle {
                visible: !panel.controller.isHeadset
                width: parent.width - Theme.spacingS * 2
                anchors.horizontalCenter: parent.horizontalCenter
                height: 1
                color: Theme.outline
                opacity: 0.5
            }

            ToggleRow {
                width: parent.width
                icon: "hearing"
                title: panel.controller.isHeadset ? "Automatic Head Detection" : "Automatic Ear Detection"
                checked: panel.controller.earDetection
                onToggled: value => panel.controller.setEarDetection(value)
            }
        }
    }

    // ---- popout ------------------------------------------------------------
    popoutWidth: 380
    popoutHeight: 480

    popoutContent: Component {
        PopoutComponent {
            headerText: ""          // the panel draws its own header
            showCloseButton: true

            PanelBody {
                width: parent.width
                controller: root
            }
        }
    }

    // ---- bar pills ---------------------------------------------------------
    horizontalBarPill: Component {
        StyledRect {
            implicitWidth: 24 + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: root.connected ? Theme.primaryContainer : Theme.surfaceContainerHigh
            border.width: root.conversation ? 2 : 0
            border.color: Theme.primary

            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.deviceIcon
                    filled: root.connected
                    size: root.iconSize
                    color: root.connected ? Theme.primary : Theme.surfaceVariantText
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.connected && root.lowestLevel >= 0 ? root.lowestLevel + "%" : (root.connected ? "On" : "-")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: root.connected ? Theme.primary : Theme.surfaceVariantText
                }
            }
        }
    }

    verticalBarPill: Component {
        StyledRect {
            width: parent.widgetThickness
            implicitHeight: pillCol.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: root.connected ? Theme.primaryContainer : Theme.surfaceContainerHigh
            border.width: root.conversation ? 2 : 0
            border.color: Theme.primary

            Column {
                id: pillCol
                anchors.centerIn: parent
                spacing: 1

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: root.deviceIcon
                    filled: root.connected
                    size: root.iconSize
                    color: root.connected ? Theme.primary : Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.connected && root.lowestLevel >= 0 ? root.lowestLevel : ""
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: Theme.primary
                }
            }
        }
    }

    // ---- Control Center tile ----------------------------------------------
    ccWidgetIcon: root.deviceIcon
    ccWidgetPrimaryText: root.deviceName
    ccWidgetSecondaryText: root.connected ? (root.modeLabel + (root.lowestLevel >= 0 ? " · " + root.lowestLevel + "%" : "")) : "Disconnected"
    ccWidgetIsActive: root.connected && root.mode !== "off"
    ccDetailHeight: 440

    onCcWidgetToggled: {
        if (root.connected)
            root.cycleAncTransparency()
    }

    // Expanding the Control Center tile reveals the full panel (same body as the
    // bar popout). Clicking the tile itself still cycles noise modes.
    ccDetailContent: Component {
        Rectangle {
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            border.width: 0

            PanelBody {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingM
                controller: root
            }
        }
    }
}
