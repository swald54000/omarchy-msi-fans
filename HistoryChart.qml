import QtQuick
import qs.Commons

// Historique des 10 dernières minutes : température CPU (ligne, axe gauche 30–100 °C)
// et tr/min du ventilateur CPU (aire, axe droit 0–rpmScale).
Canvas {
  id: chart

  property var history: []          // [{ t: ms, cpuTemp: °C, cpuRpm: tr/min }]
  property real rpmScale: 6000
  property color foreground: "white"
  property color accent: "cyan"
  property string fontFamily: ""

  readonly property real windowMs: 600000
  readonly property real tMin: 30
  readonly property real tMax: 100

  implicitHeight: Style.space(90)
  antialiasing: true

  onHistoryChanged: requestPaint()
  onRpmScaleChanged: requestPaint()
  onForegroundChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    var px = Style.font.caption
    var left = px * 2.6, right = px * 3.2, top = 4, bottom = px * 1.6
    var w = width - left - right, h = height - top - bottom
    var now = history.length > 0 ? history[history.length - 1].t : 0
    var x = function(t) { return left + (1 - (now - t) / windowMs) * w }
    var yTemp = function(c) { return top + h - (Math.max(tMin, Math.min(tMax, c)) - tMin) / (tMax - tMin) * h }
    var yRpm = function(r) { return top + h - Math.max(0, Math.min(rpmScale, r)) / rpmScale * h }

    ctx.reset()
    ctx.font = px + "px \"" + fontFamily + "\""
    ctx.lineWidth = 1
    ctx.strokeStyle = Qt.rgba(foreground.r, foreground.g, foreground.b, 0.15)
    ctx.strokeRect(left, top, w, h)
    ctx.fillStyle = Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
    ctx.textAlign = "right"
    ctx.fillText(tMax + "°", left - 4, top + px)
    ctx.fillText(tMin + "°", left - 4, top + h)
    ctx.textAlign = "left"
    ctx.fillText(Math.round(rpmScale / 1000) + "k", left + w + 4, top + px)
    ctx.fillText("0", left + w + 4, top + h)
    ctx.textAlign = "center"
    ctx.fillText("−10 min", left + px * 2, height - 2)
    ctx.fillText("maintenant", left + w - px * 3, height - 2)

    if (history.length < 2) return

    var visible = history.filter(function(p) { return now - p.t <= windowMs })

    ctx.fillStyle = Qt.rgba(accent.r, accent.g, accent.b, 0.25)
    ctx.beginPath()
    ctx.moveTo(x(visible[0].t), top + h)
    visible.forEach(function(p) { ctx.lineTo(x(p.t), yRpm(p.cpuRpm)) })
    ctx.lineTo(x(visible[visible.length - 1].t), top + h)
    ctx.closePath()
    ctx.fill()

    ctx.lineWidth = 2
    ctx.strokeStyle = foreground
    ctx.beginPath()
    visible.forEach(function(p, i) {
      if (i === 0) ctx.moveTo(x(p.t), yTemp(p.cpuTemp))
      else ctx.lineTo(x(p.t), yTemp(p.cpuTemp))
    })
    ctx.stroke()
  }
}
