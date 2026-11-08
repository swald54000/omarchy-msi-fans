import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Contrôle des ventilateurs des portables MSI pilotés par msi-ec. Lectures et écritures
// passent directement par sysfs (/sys/devices/platform/msi-ec) : l'écriture est permise
// aux membres du groupe msi-ec par une règle udev du correctif 1 de msi-gs76-linux.
Panel {
  id: root
  moduleName: "swald.fans"
  ipcTarget: "swald.fans"

  property string writeMessage: ""
  property string dgpuAddr: ""
  property bool dgpuChecked: false
  property bool hwmonStale: false
  property int hwmonIdleTicks: 0
  property var history: []
  property int rpmPeak: 0
  property string curveTab: "cpu"
  property string hwmonDir: ""

  readonly property string ecDir: "/sys/devices/platform/msi-ec"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/swald.fans"
  readonly property var feat: Model.features({
    hwmon: hwmonDir, fan1: fan1File.value, fan3: fan3File.value, cpuCurve: cpuCurveFile.value,
    cpuHyst: cpuHystFile.value, usb: usbFile.value
  })
  // NaN = lecture ratée (fichier vide ou disparu, -ENODATA, -EIO) : affiché « — », jamais 0.
  readonly property real cpuTemp: Model.num(cpuTempFile.value)
  readonly property real cpuSpeed: Model.num(cpuSpeedFile.value)
  readonly property real gpuTemp: Model.num(gpuTempFile.value)
  readonly property real gpuSpeed: Model.num(gpuSpeedFile.value)
  readonly property real cpuRpm: Model.num(fan1File.value)
  readonly property real gpuRpm: Model.num(fan2File.value)
  readonly property real auxRpm: Model.num(fan3File.value)
  readonly property string gpuState: Model.gpuState(gpuTempFile.value, gpuRuntimeFile.value,
    dgpuChecked ? dgpuAddr : undefined)
  readonly property bool gpuAsleep: gpuState === "veille"
  readonly property bool gpuAbsent: gpuState === "absent"
  readonly property var shownCurve: Model.parseCurve(curveTab === "cpu" ? cpuCurveFile.value : gpuCurveFile.value)
  readonly property var shownHyst: Model.parseHysteresis(curveTab === "cpu" ? cpuHystFile.value : gpuHystFile.value)
  readonly property int spinMs: Model.spinDuration(cpuRpm)
  // Statut lu dans sysfs ; les listes available_* (une valeur par ligne) deviennent des
  // chaînes séparées par des espaces, comme l'attend Model.validAction.
  readonly property var status: ({
    fan_mode: fanModeFile.value.trim(),
    fan_modes: spaced(fanModesFile.value),
    shift_mode: shiftModeFile.value.trim(),
    shift_modes: spaced(shiftModesFile.value),
    cooler_boost: boostFile.value.trim()
  })
  readonly property bool available: fanModeFile.value.trim() !== ""
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property var fanModes: words(status.fan_modes)
  readonly property var shiftModes: words(status.shift_modes)
  readonly property bool boosting: status.cooler_boost === "on"

  // Every selectable button, in panel order, for keyboard navigation.
  readonly property var actions: {
    var list = []
    if (feat.curve) {
      list.push({ attr: "tab", value: "cpu" })
      list.push({ attr: "tab", value: "gpu" })
    }
    fanModes.forEach(function(m) { list.push({ attr: "fan_mode", value: m }) })
    list.push({ attr: "cooler_boost", value: boosting ? "off" : "on" })
    shiftModes.forEach(function(m) { list.push({ attr: "shift_mode", value: m }) })
    return list
  }

  readonly property var labels: ({
    auto: "Auto",
    silent: "Silencieux",
    advanced: "Avancé",
    turbo: "Turbo",
    comfort: "Confort",
    eco: "Éco"
  })

  readonly property var icons: ({
    auto: "󰁨",
    silent: "󰖔",
    advanced: "󰒓",
    turbo: "󱐋",
    comfort: "󰾅",
    eco: "󰌪"
  })

  function words(value) {
    var text = String(value || "").trim()
    return text === "" ? [] : text.split(/\s+/)
  }

  function label(value) {
    return labels[value] || value
  }

  function spaced(value) {
    return words(value).join(" ")
  }

  function pct(v) { return isFinite(v) ? v + " %" : "—" }

  function refresh() {
    [fanModeFile, fanModesFile, shiftModeFile, shiftModesFile, boostFile].forEach(function(f) { f.reload() })
  }

  // Cherche de nouveau le hwmon de msi-ec (au plus un lancement par tick d'échantillonnage).
  function findHwmon() {
    if (!hwmonProc.running) hwmonProc.running = true
  }

  // Re-read every sysfs file, then record one history sample.
  function sample() {
    var files = [cpuTempFile, cpuSpeedFile, gpuTempFile, gpuSpeedFile, gpuRuntimeFile,
                 cpuCurveFile, gpuCurveFile, cpuHystFile, gpuHystFile, usbFile,
                 fanModeFile, fanModesFile, shiftModeFile, shiftModesFile, boostFile,
                 fan1File, fan2File, fan3File]
    files.forEach(function(f) { if (f.path !== "") f.reload() })
    if (available) {
      if (hwmonDir !== "" && hwmonStale) {
        // Lecture de fan1_input ratée : le hwmon a pu changer de numéro (rechargement du pilote).
        hwmonStale = false
        findHwmon()
      } else if (hwmonDir === "" && ++hwmonIdleTicks >= 5) {
        hwmonIdleTicks = 0
        findHwmon()
      }
    }
    if (!feat.rpm) return
    var s = { t: Date.now(), cpuTemp: cpuTemp, cpuRpm: cpuRpm }
    if (!Model.validSample(s)) return
    history = Model.pushSample(history, s, 300)
    var peak = Model.filterPeak(history, rpmPeak)
    if (peak !== rpmPeak) {
      rpmPeak = peak
      peakFile.setText(String(rpmPeak) + "\n")
    }
  }

  function apply(attr, value) {
    if (attr === "tab") { curveTab = value; return }
    if (actionProc.running) return
    if (!Model.validAction(attr, value, status)) return
    actionExit = -1
    actionErr = null
    // Chemin et valeur passés en arguments ($1, $2), jamais interpolés dans le script.
    actionProc.command = ["sh", "-c", "printf '%s' \"$2\" > \"$1\"", "sh", ecDir + "/" + attr, value]
    actionProc.running = true
  }

  // Le code de sortie et la sortie d'erreur arrivent séparément : on conclut quand on a les deux.
  property int actionExit: -1
  property var actionErr: null
  function finishAction() {
    if (actionExit < 0 || actionErr === null) return
    writeMessage = Model.writeError(actionExit, actionErr)
    actionExit = -1
    actionErr = null
    refresh()
  }

  function actionIndex(attr, value) {
    for (var i = 0; i < actions.length; ++i) {
      if (actions[i].attr === attr && (attr === "cooler_boost" || actions[i].value === value)) return i
    }
    return -1
  }

  function moveCursor(delta) {
    if (actions.length === 0) return
    cursorIndex = (cursorIndex + delta + actions.length) % actions.length
  }

  function activateCursor() {
    var action = actions[cursorIndex]
    if (action) apply(action.attr, action.value)
  }

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      cursorIndex = Math.max(0, actionIndex("fan_mode", status.fan_mode))
    }
  }

  visible: available
  implicitWidth: available ? button.implicitWidth : 0
  implicitHeight: available ? button.implicitHeight : 0

  // GPU dédié : lignes « adresse vendor classe » des périphériques PCI ; vide = aucun.
  Process {
    id: dgpuProc
    running: true
    command: ["sh", "-c", "for d in /sys/bus/pci/devices/*; do [ -r \"$d/vendor\" ] && [ -r \"$d/class\" ] || continue; printf '%s %s %s\\n' \"${d##*/}\" \"$(cat \"$d/vendor\")\" \"$(cat \"$d/class\")\"; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.dgpuAddr = Model.findDgpu(text.split("\n"))
        root.dgpuChecked = true
      }
    }
  }

  // hwmon de msi-ec (branche gs76) ; vide avec le pilote d'origine.
  Process {
    id: hwmonProc
    running: true
    command: ["sh", "-c", "mkdir -p \"$1\"; h=$(grep -lx msi_ec /sys/class/hwmon/hwmon*/name | head -n1) && dirname \"$h\"", "sh", root.statePath]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.hwmonDir = text.trim() }
  }

  component SysFile: FileView {
    property string value: ""
    blockLoading: true
    printErrors: false
    onLoaded: value = text()
    signal failed()
    onLoadFailed: { value = ""; failed() }
  }

  SysFile { id: cpuTempFile; path: root.ecDir + "/cpu/realtime_temperature" }
  SysFile { id: cpuSpeedFile; path: root.ecDir + "/cpu/realtime_fan_speed" }
  SysFile { id: gpuTempFile; path: root.ecDir + "/gpu/realtime_temperature" }
  SysFile { id: gpuSpeedFile; path: root.ecDir + "/gpu/realtime_fan_speed" }
  SysFile {
    id: gpuRuntimeFile
    path: root.dgpuAddr === "" ? "" : "/sys/bus/pci/devices/" + root.dgpuAddr + "/power/runtime_status"
  }
  SysFile { id: cpuCurveFile; path: root.ecDir + "/cpu/fan_curve" }
  SysFile { id: gpuCurveFile; path: root.ecDir + "/gpu/fan_curve" }
  SysFile { id: cpuHystFile; path: root.ecDir + "/cpu/fan_curve_hysteresis" }
  SysFile { id: gpuHystFile; path: root.ecDir + "/gpu/fan_curve_hysteresis" }
  SysFile { id: usbFile; path: root.ecDir + "/usb_share" }
  SysFile { id: fanModeFile; path: root.ecDir + "/fan_mode" }
  SysFile { id: fanModesFile; path: root.ecDir + "/available_fan_modes" }
  SysFile { id: shiftModeFile; path: root.ecDir + "/shift_mode" }
  SysFile { id: shiftModesFile; path: root.ecDir + "/available_shift_modes" }
  SysFile { id: boostFile; path: root.ecDir + "/cooler_boost" }
  SysFile { id: fan1File; path: root.hwmonDir === "" ? "" : root.hwmonDir + "/fan1_input"; onFailed: root.hwmonStale = true }
  SysFile { id: fan2File; path: root.hwmonDir === "" ? "" : root.hwmonDir + "/fan2_input" }
  SysFile { id: fan3File; path: root.hwmonDir === "" ? "" : root.hwmonDir + "/fan3_input" }

  FileView {
    id: peakFile
    path: root.statePath + "/rpm-peak"
    printErrors: false
    atomicWrites: true
    onLoaded: root.rpmPeak = Math.max(root.rpmPeak, Number(text().trim()) || 0)
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.actionErr = text; root.finishAction() }
    }
    onExited: function(exitCode, exitStatus) { root.actionExit = exitCode; root.finishAction() }
  }

  // sysfs reads are cheap (~1.4 ms per EC byte): sample every 2 s so the
  // history is already filled when the panel opens.
  Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.sample() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰈐"
    tooltipText: root.feat.rpm && isFinite(root.cpuTemp) ? Model.tooltip(root.cpuTemp, root.cpuRpm) : ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.apply("cooler_boost", root.boosting ? "off" : "on")
      else root.toggle()
    }

    // Spins at a speed proportional to the real CPU fan RPM (fixed when stopped).
    RotationAnimator on rotation {
      running: (root.boosting || root.spinMs > 0) && !Style.reduceMotion
      from: 0
      to: 360
      duration: root.spinMs > 0 ? root.spinMs : 900
      loops: Animation.Infinite
      onRunningChanged: if (!running) button.rotation = 0
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.available
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx !== 0 ? dx : dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: fan icon · title/status ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰈐"
            color: root.boosting ? Color.accent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            RotationAnimator on rotation {
              running: root.opened && root.boosting && !Style.reduceMotion
              from: 0
              to: 360
              duration: 900
              loops: Animation.Infinite
              onRunningChanged: if (!running) heroIcon.rotation = 0
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Ventilateurs"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: (root.boosting ? "Cooler Boost actif" : "Mode " + root.label(root.status.fan_mode)
                + " · " + root.label(root.status.shift_mode)).toUpperCase()
              color: root.boosting ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Live readings ----------
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          InfoPair {
            label: "CPU"
            value: Model.formatTemp(root.cpuTemp) + " · " + root.pct(root.cpuSpeed)
              + (root.feat.rpm ? " · " + Model.formatRpm(root.cpuRpm) : "")
          }
          InfoPair {
            label: "GPU"
            value: root.gpuAbsent ? "GPU absent"
              : root.gpuAsleep ? "GPU en veille"
              : Model.formatTemp(root.gpuTemp) + " · " + root.pct(root.gpuSpeed)
                + (root.feat.rpm ? " · " + Model.formatRpm(root.gpuRpm) : "")
          }
          InfoPair {
            visible: root.feat.aux
            label: "Ventilateur auxiliaire"
            value: Model.formatRpm(root.auxRpm)
          }
        }

        // ---------- Fan curve ----------
        PanelSeparator { foreground: root.bar.foreground; visible: root.feat.curve }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.feat.curve

          Row {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "COURBE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.verticalCenter: parent.verticalCenter
            }

            Repeater {
              model: ["cpu", "gpu"]
              Button {
                required property var modelData
                readonly property int actionIndex: root.actionIndex("tab", String(modelData))
                text: String(modelData).toUpperCase()
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: root.curveTab === modelData
                hasCursor: root.cursorActive && root.cursorIndex === actionIndex
                onClicked: root.apply("tab", String(modelData))
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.cursorIndex = actionIndex
                  }
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.status.fan_mode === "advanced"
              text: "Courbe appliquée"
              color: Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          CurveChart {
            width: parent.width
            curve: root.shownCurve
            hysteresis: root.shownHyst
            liveTemp: root.curveTab === "cpu" ? root.cpuTemp : root.gpuTemp
            liveSpeed: root.curveTab === "cpu" ? root.cpuSpeed : root.gpuSpeed
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
          }
        }

        // ---------- History ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.feat.rpm

          PanelSectionHeader {
            text: "10 DERNIÈRES MINUTES · °C CPU / TR/MIN"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          HistoryChart {
            width: parent.width
            history: root.history
            rpmScale: Model.rpmScale(root.rpmPeak, root.history)
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
          }
        }

        // ---------- Fan mode ----------
        PanelSeparator { foreground: root.bar.foreground }

        ModeSection {
          title: "MODE VENTILATEURS"
          attr: "fan_mode"
          modes: root.fanModes
          current: root.status.fan_mode || ""
        }

        Button {
          width: parent.width
          iconText: "󰈐"
          iconSize: Style.font.title
          iconSpinning: root.boosting && !Style.reduceMotion
          text: root.boosting ? "Cooler Boost : activé" : "Cooler Boost : désactivé"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          active: root.boosting
          hasCursor: root.cursorActive && root.cursorIndex === root.actionIndex("cooler_boost", "")
          onClicked: root.apply("cooler_boost", root.boosting ? "off" : "on")
          onHovered: function(h) {
            if (h) {
              root.cursorActive = true
              root.cursorIndex = root.actionIndex("cooler_boost", "")
            }
          }
        }

        // ---------- Performance (shift) mode ----------
        PanelSeparator { foreground: root.bar.foreground }

        ModeSection {
          title: "PERFORMANCE"
          attr: "shift_mode"
          modes: root.shiftModes
          current: root.status.shift_mode || ""
        }

        InfoPair {
          visible: root.feat.usb
          label: "Recharge USB portable éteint"
          value: Model.usbLabel(usbFile.value) || ""
        }

        Text {
          visible: root.writeMessage !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.writeMessage
          wrapMode: Text.WordWrap
          color: Color.accent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  component ModeSection: Column {
    property string title: ""
    property string attr: ""
    property var modes: []
    property string current: ""

    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader {
      text: parent.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Row {
      id: modeRow
      width: parent.width
      spacing: Style.space(6)

      readonly property string attr: parent.attr
      readonly property string current: parent.current
      readonly property real cellWidth: parent.modes.length > 0
        ? (width - spacing * (parent.modes.length - 1)) / parent.modes.length
        : 0

      Repeater {
        model: modeRow.parent.modes
        Button {
          required property var modelData
          readonly property int actionIndex: root.actionIndex(modeRow.attr, String(modelData))
          width: modeRow.cellWidth
          iconText: root.icons[modelData] || ""
          iconSize: Style.font.title
          text: root.label(String(modelData))
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          active: modeRow.current === modelData
          hasCursor: root.cursorActive && root.cursorIndex === actionIndex
          onClicked: root.apply(modeRow.attr, String(modelData))
          onHovered: function(h) {
            if (h) {
              root.cursorActive = true
              root.cursorIndex = actionIndex
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
