import QtQuick
import qs.Commons
import "Model.js" as Model

// Courbe de ventilation en escalier (montée), seuils de descente en pointillés,
// point en direct (température, vitesse réelle demandée par l'EC).
Canvas {
  id: chart

  property var curve: null
  property var hysteresis: null
  property real liveTemp: 0
  property real liveSpeed: 0
  property color foreground: "white"
  property color accent: "cyan"
  property string fontFamily: ""

  readonly property real tMin: 30
  readonly property real tMax: 100
  readonly property real sMax: 150

  implicitHeight: Style.space(140)
  antialiasing: true

  onCurveChanged: requestPaint()
  onHysteresisChanged: requestPaint()
  onLiveTempChanged: requestPaint()
  onLiveSpeedChanged: requestPaint()
  onForegroundChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    var px = Style.font.caption
    var left = px * 2.6, right = 4, top = 4, bottom = px * 1.6
    var w = width - left - right, h = height - top - bottom
    var x = function(t) { return left + (Math.max(tMin, Math.min(tMax, t)) - tMin) / (tMax - tMin) * w }
    var y = function(s) { return top + h - Math.max(0, Math.min(sMax, s)) / sMax * h }

    ctx.reset()
    ctx.font = px + "px \"" + fontFamily + "\""
    ctx.lineWidth = 1

    // Grille et graduations.
    ctx.strokeStyle = Qt.rgba(foreground.r, foreground.g, foreground.b, 0.15)
    ctx.fillStyle = Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
    ctx.textAlign = "center"
    for (var t = 40; t <= 100; t += 20) {
      ctx.beginPath(); ctx.moveTo(x(t), top); ctx.lineTo(x(t), top + h); ctx.stroke()
      ctx.textAlign = t === tMax ? "right" : "center"
      ctx.fillText(t + "°", x(t), height - 2)
    }
    ctx.textAlign = "right"
    for (var s = 0; s <= 150; s += 50) {
      ctx.beginPath(); ctx.moveTo(left, y(s)); ctx.lineTo(left + w, y(s)); ctx.stroke()
      ctx.fillText(s + "%", left - 4, y(s) + px / 3)
    }

    if (!curve) {
      ctx.textAlign = "center"
      ctx.fillText("—", left + w / 2, top + h / 2)
      return
    }

    var steps = function(temps) {
      ctx.beginPath()
      ctx.moveTo(x(tMin), y(curve.speeds[0]))
      for (var i = 0; i < temps.length; i++) {
        ctx.lineTo(x(temps[i]), y(curve.speeds[i]))
        ctx.lineTo(x(temps[i]), y(curve.speeds[i + 1]))
      }
      ctx.lineTo(x(tMax), y(curve.speeds[curve.speeds.length - 1]))
      ctx.stroke()
    }

    if (hysteresis) {
      ctx.setLineDash([3, 3])
      ctx.strokeStyle = Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
      steps(Model.downThresholds(curve, hysteresis))
      ctx.setLineDash([])
    }
    ctx.lineWidth = 2
    ctx.strokeStyle = foreground
    steps(curve.temps)

    // Point en direct (absent si la lecture a échoué).
    if (!isFinite(liveTemp) || !isFinite(liveSpeed)) return
    ctx.fillStyle = accent
    ctx.beginPath()
    ctx.arc(x(liveTemp), y(liveSpeed), 4, 0, 2 * Math.PI)
    ctx.fill()
  }
}
