import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon + popup for the solar-nightlight daemon. The daemon publishes its
// state to ~/.cache/solar-nightlight/state.json; the panel only reads that
// file and changes the brightness offset through the daemon's own CLI
// (argv array, never a shell string).
Panel {
  id: root
  moduleName: "specialkapa.solar-nightlight"
  ipcTarget: "specialkapa.solar-nightlight"

  readonly property string daemonPath: String(Qt.resolvedUrl("bin/solar-nightlight")).replace(/^file:\/\//, "")
  readonly property string statePath: Quickshell.env("HOME") + "/.cache/solar-nightlight/state.json"

  property var state: ({})
  property real now: Date.now() / 1000

  // Pending override chosen in the panel, applied with the Apply button.
  property int pendingOffset: 0
  property int pendingMinutes: 60
  readonly property var durations: [30, 60, 120, 240, 0]

  readonly property bool hasState: state.current_phase !== undefined
  readonly property bool offsetActive: state.offset_active === true
  readonly property int offset: offsetActive ? (state.brightness_offset | 0) : 0
  readonly property int baseBrightness: state.base_brightness !== undefined ? state.base_brightness | 0 : 0
  readonly property int brightness: state.brightness !== undefined ? state.brightness | 0 : 0
  readonly property bool isNight: state.current_phase === "NIGHT" || state.current_phase === "SUNSET_TRANSITION"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function glyph() {
    var phase = state.current_phase
    if (phase === "NIGHT") return String.fromCodePoint(0xF0594)            // weather-night
    if (phase === "SUNSET_TRANSITION") return String.fromCodePoint(0xF059A) // weather-sunset
    if (phase === "SUNRISE_TRANSITION") return String.fromCodePoint(0xF059C)// weather-sunset-up
    return String.fromCodePoint(0xF0599)                                    // weather-sunny
  }

  function signed(n) {
    return (n > 0 ? "+" : n < 0 ? "−" : "±") + Commons.I18n.formatNumber(Math.abs(n))
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function formatTime(epoch) {
    if (typeof epoch !== "number" || !isFinite(epoch)) return "—"
    return new Date(epoch * 1000).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  function offsetText() {
    if (!offsetActive) return strings.t("info.none")
    var exp = state.offset_expires_at
    if (typeof exp !== "number") return strings.t("offset.untilCleared").arg(signed(offset))
    var mins = Math.max(1, Math.ceil((exp - now) / 60))
    return strings.tn("offset.minutesLeft", mins).arg(Commons.I18n.formatNumber(mins)).arg(signed(offset))
  }

  function cloudText() {
    if (state.clouds_enabled === false) return strings.t("info.cloudsOff")
    if (typeof state.cloud_cover === "number" && isFinite(state.cloud_cover))
      return Commons.I18n.formatNumber(Math.round(state.cloud_cover)) + "%"
    if (state.current_phase === "NIGHT") return strings.t("info.cloudsNight")
    return strings.t("info.cloudsNA")
  }

  // ---- Colour temperature scale ----
  readonly property int dayTemp: (state.day_temp | 0) > 0 ? state.day_temp | 0 : 6500
  readonly property int nightTemp: (state.night_temp | 0) > 0 ? state.night_temp | 0 : 4000
  readonly property int targetTemp: state.target_temp | 0
  readonly property int actualTemp: (state.actual_temp | 0) > 0 ? state.actual_temp | 0 : targetTemp
  // The scale covers night..day, widened if a manual setting falls outside it.
  readonly property int scaleMin: Math.min(nightTemp, dayTemp, actualTemp > 0 ? actualTemp : nightTemp)
  readonly property int scaleMax: Math.max(nightTemp, dayTemp, actualTemp)
  readonly property bool tempManual: state.override_active === true || (actualTemp > 0 && Math.abs(actualTemp - targetTemp) > 80)

  function tempFraction(k) {
    var span = scaleMax - scaleMin
    return span > 0 ? clamp((k - scaleMin) / span, 0, 1) : 0.5
  }

  // Black-body colour approximation (Tanner Helland), 1000K-40000K.
  function kelvinColor(k) {
    var t = clamp(k, 1000, 40000) / 100
    var r, g, b
    if (t <= 66) {
      r = 255
      g = 99.4708025861 * Math.log(t) - 161.1195681661
      b = t <= 19 ? 0 : 138.5177312231 * Math.log(t - 10) - 305.0447927307
    } else {
      r = 329.698727446 * Math.pow(t - 60, -0.1332047592)
      g = 288.1221695283 * Math.pow(t - 60, -0.0755148492)
      b = 255
    }
    return Qt.rgba(clamp(r, 0, 255) / 255, clamp(g, 0, 255) / 255, clamp(b, 0, 255) / 255, 1)
  }

  function durationLabel(m) {
    if (m === 0) return strings.t("duration.forever")
    if (m < 60) return strings.t("duration.minutes").arg(Commons.I18n.formatNumber(m))
    return strings.t("duration.hours").arg(Commons.I18n.formatNumber(m / 60))
  }

  function parseState(text) {
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) state = parsed
  }

  function runCli(args) {
    if (cliProc.running) return
    cliProc.command = ["python3", root.daemonPath].concat(args)
    cliProc.running = true
  }

  function applyOffset() {
    var off = clamp(pendingOffset, -100, 100) | 0
    if (off === 0) runCli(["--clear-offset"])
    else runCli(["--offset", String(off), "--for", String(clamp(pendingMinutes, 0, 10080) | 0)])
  }

  function resetOffset() {
    pendingOffset = 0
    runCli(["--clear-offset"])
  }

  onOpenedChanged: {
    if (opened) {
      stateFile.reload()
      now = Date.now() / 1000
      pendingOffset = offset
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseState(text())
  }

  // The daemon replaces state.json atomically each tick; if inotify misses the
  // new inode this keeps the icon and panel current anyway.
  Timer {
    interval: root.opened ? 5000 : 30000
    running: true
    repeat: true
    onTriggered: {
      stateFile.reload()
      root.now = Date.now() / 1000
    }
  }

  Process {
    id: cliProc
    onExited: stateFile.reload()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph()
    labelText: root.offsetActive && !vertical ? root.signed(root.offset) : ""
    slotSize: Style.bar.iconSlot * (root.offsetActive && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.resetOffset()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.pendingOffset = root.clamp(root.pendingOffset + dx * 5, -50, 50)
      }
      onActivateRequested: root.applyOffset()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroValue.implicitHeight)

          PlainText {
            id: heroIcon
            text: root.glyph()
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroValue.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              text: strings.t("title")
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            PlainText {
              text: (root.hasState
                ? strings.t("status.line")
                    .arg(strings.t("phase." + root.state.current_phase))
                    .arg(Commons.I18n.formatNumber(root.state.target_temp | 0))
                    .arg(Commons.I18n.formatNumber(Number(root.state.elevation) || 0, 1))
                : strings.t("status.waiting")).toUpperCase()
              opacity: 0.7
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          PlainText {
            id: heroValue
            text: root.hasState && root.state.brightness_enabled !== false ? Commons.I18n.formatNumber(root.brightness) + "%" : "—"
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Info ----------
        Row {
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: strings.t("info.sunrise"); value: root.formatTime(root.state.sunrise) }
            InfoPair { label: strings.t("info.sunset"); value: root.formatTime(root.state.sunset) }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: strings.t("info.solar"); value: root.hasState ? Commons.I18n.formatNumber(root.baseBrightness) + "%" : "—" }
            InfoPair {
              label: strings.t("info.displays")
              value: Array.isArray(root.state.displays) ? Commons.I18n.formatNumber(root.state.displays.length) : "—"
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          InfoPair {
            label: strings.t("info.location")
            value: root.state.location ? String(root.state.location.city || "—") : "—"
          }
          InfoPair { label: strings.t("info.clouds"); value: root.cloudText() }
          InfoPair { label: strings.t("info.offset"); value: root.offsetText() }
        }

        // ---------- Colour temperature scale ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.hasState

          Item {
            width: parent.width
            implicitHeight: tempHeader.implicitHeight

            PanelSectionHeader {
              id: tempHeader
              text: strings.t("temp.header")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            PlainText {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.tempManual
                ? strings.t("temp.manual").arg(Commons.I18n.formatNumber(root.actualTemp)).arg(Commons.I18n.formatNumber(root.targetTemp))
                : strings.t("temp.kelvin").arg(Commons.I18n.formatNumber(root.actualTemp))
              font.pixelSize: Style.font.bodySmall
            }
          }

          Item {
            id: scale
            width: parent.width
            readonly property real knob: Style.space(12)
            implicitHeight: knob + Style.space(2)

            Rectangle {
              id: tempTrack
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: scale.knob / 2
              anchors.rightMargin: scale.knob / 2
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(4)
              radius: height / 2
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: root.kelvinColor(root.scaleMin) }
                GradientStop { position: 0.25; color: root.kelvinColor(root.scaleMin + (root.scaleMax - root.scaleMin) * 0.25) }
                GradientStop { position: 0.5; color: root.kelvinColor(root.scaleMin + (root.scaleMax - root.scaleMin) * 0.5) }
                GradientStop { position: 0.75; color: root.kelvinColor(root.scaleMin + (root.scaleMax - root.scaleMin) * 0.75) }
                GradientStop { position: 1.0; color: root.kelvinColor(root.scaleMax) }
              }
            }

            // Where the sun schedule wants to be, shown only while a manual
            // temperature differs from it.
            Rectangle {
              visible: root.tempManual
              width: Style.space(2)
              height: tempTrack.height + Style.space(6)
              radius: width / 2
              anchors.verticalCenter: tempTrack.verticalCenter
              x: tempTrack.x + tempTrack.width * (LayoutMirroring.enabled ? 1 - root.tempFraction(root.targetTemp) : root.tempFraction(root.targetTemp)) - width / 2
              color: root.bar.foreground
              opacity: 0.6
            }

            // Current temperature marker.
            Rectangle {
              width: scale.knob
              height: scale.knob
              radius: width / 2
              anchors.verticalCenter: tempTrack.verticalCenter
              x: tempTrack.x + tempTrack.width * (LayoutMirroring.enabled ? 1 - root.tempFraction(root.actualTemp) : root.tempFraction(root.actualTemp)) - width / 2
              color: root.kelvinColor(root.actualTemp)
              border.width: Style.space(2)
              border.color: root.bar.foreground

              Behavior on x { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
            }
          }

          Item {
            width: parent.width
            implicitHeight: warmLabel.implicitHeight

            PlainText {
              id: warmLabel
              anchors.left: parent.left
              text: strings.t("temp.warm") + " · " + strings.t("temp.kelvin").arg(Commons.I18n.formatNumber(root.scaleMin))
              opacity: 0.6
              font.pixelSize: Style.font.caption
            }

            PlainText {
              anchors.right: parent.right
              text: strings.t("temp.kelvin").arg(Commons.I18n.formatNumber(root.scaleMax)) + " · " + strings.t("temp.cool")
              opacity: 0.6
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            visible: root.tempManual
            width: parent.width
            text: strings.t("temp.resume")
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.runCli(["--force"])
          }
        }

        PlainText {
          visible: root.state.brightness_enabled === false
          text: strings.t("info.disabled")
          opacity: 0.6
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Override ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: header.implicitHeight

            PanelSectionHeader {
              id: header
              text: strings.t("override.header")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            PlainText {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("override.value")
                .arg(root.signed(root.pendingOffset))
                .arg(Commons.I18n.formatNumber(root.clamp(root.baseBrightness + root.pendingOffset, 0, 100)))
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: -50
            maximum: 50
            step: 5
            integer: true
            tickCount: 11
            value: root.pendingOffset
            onMoved: function(v) { root.pendingOffset = Math.round(v / 5) * 5 }
            onReleased: function(v) { root.pendingOffset = Math.round(v / 5) * 5 }
            onRightClicked: root.pendingOffset = 0
          }

          PanelSectionHeader {
            text: strings.t("duration.header")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: durationRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (root.durations.length - 1)) / root.durations.length

            Repeater {
              model: root.durations
              Button {
                required property var modelData
                width: durationRow.cellWidth
                text: root.durationLabel(modelData)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: root.pendingMinutes === modelData
                onClicked: root.pendingMinutes = modelData
              }
            }
          }

          Row {
            id: actionRow
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (actionRow.width - actionRow.spacing) / 2
              text: strings.t("action.reset")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.resetOffset()
            }

            Button {
              width: (actionRow.width - actionRow.spacing) / 2
              text: strings.t("action.apply")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              active: true
              onClicked: root.applyOffset()
            }
          }
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    PlainText { id: l; text: label; opacity: 0.6; font.pixelSize: Style.font.bodySmall }
    Item { width: Math.max(0, parent.width - l.implicitWidth - v.implicitWidth - parent.spacing * 2); height: 1 }
    PlainText { id: v; text: value; font.pixelSize: Style.font.bodySmall }
  }
}
