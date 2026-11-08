// Logique pure du widget swald.fans (pas d'accès aux fichiers ni à Qt) : décodage des
// fichiers sysfs de msi-ec (branche gs76), historique tournant, formats d'affichage.
// Testé sous node par tests/Model.test.mjs.

// Nombre lu dans un fichier sysfs ; NaN si la lecture a échoué (texte vide ou invalide).
function num(text) {
  var t = String(text === undefined || text === null ? "" : text).trim()
  return t === "" ? NaN : Number(t)
}

function formatTemp(t) {
  return isFinite(t) ? t + " °C" : "—"
}

// Un échantillon n'entre dans l'historique que si les deux lectures ont réussi.
function validSample(s) {
  return isFinite(s.cpuTemp) && isFinite(s.cpuRpm)
}

function ints(text) {
  var t = String(text || "").trim()
  if (t === "") return []
  return t.split(/\s+/).map(function(v) { return Number(v) })
}

// "s0 t1 s1 … t6 s6" → { temps: [t1..t6], speeds: [s0..s6] }
function parseCurve(text) {
  var v = ints(text)
  if (v.length !== 13 || v.some(function(n) { return !isFinite(n) })) return null
  var temps = [], speeds = [v[0]]
  for (var i = 0; i < 6; i++) {
    temps.push(v[1 + 2 * i])
    speeds.push(v[2 + 2 * i])
  }
  return { temps: temps, speeds: speeds }
}

function parseHysteresis(text) {
  var v = ints(text)
  if (v.length !== 6 || v.some(function(n) { return !isFinite(n) })) return null
  return v
}

// Seuils de descente : montée − écart.
function downThresholds(curve, hyst) {
  return curve.temps.map(function(t, i) { return t - hyst[i] })
}

// Vitesse demandée par la courbe en montée.
function speedAt(curve, temp) {
  var speed = curve.speeds[0]
  for (var i = 0; i < curve.temps.length; i++) {
    if (temp >= curve.temps[i]) speed = curve.speeds[i + 1]
  }
  return speed
}

function pushSample(history, sample, max) {
  var next = history.slice(Math.max(0, history.length + 1 - max))
  next.push(sample)
  return next
}

// Durée d'un tour de l'icône (ms) ; 0 = icône fixe.
function spinDuration(rpm) {
  if (!(rpm > 0)) return 0
  return Math.max(400, Math.min(4000, Math.round(3000000 / rpm)))
}

// dgpu : adresse PCI du GPU dédié ("" = aucun ; undefined = non précisé).
function gpuState(tempText, runtimeStatus, dgpu) {
  if (dgpu === "") return "absent"
  if (String(runtimeStatus || "").trim() === "suspended") return "veille"
  var t = num(tempText)
  if (!isFinite(t)) return "inconnu"
  return t > 0 ? "actif" : "veille"
}

function groupThousands(n) {
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, " ")
}

function formatRpm(rpm) {
  var n = Number(rpm)
  if (String(rpm).trim() === "" || !isFinite(n)) return "—"
  return n === 0 ? "arrêté" : groupThousands(n) + " tr/min"
}

function usbLabel(text) {
  var t = String(text || "").trim()
  if (t === "on") return "activée"
  if (t === "off") return "désactivée"
  return null
}

// files : textes lus ("" si le fichier est absent) ; hwmon = dossier hwmon msi_ec ("" si absent).
function features(files) {
  var present = function(t) { return String(t || "").trim() !== "" }
  return {
    rpm: present(files.hwmon),
    aux: present(files.fan3),
    curve: parseCurve(files.cpuCurve) !== null,
    hyst: parseHysteresis(files.cpuHyst) !== null,
    usb: usbLabel(files.usb) !== null
  }
}

// Échelle des tr/min de l'historique : au moins 6000, sinon le plus haut jamais vu.
function rpmScale(peak, history) {
  return Math.max(6000, filterPeak(history, peak))
}

function tooltip(cpuTemp, rpm) {
  return "CPU " + cpuTemp + " °C · " + formatRpm(rpm)
}

// Attributs sysfs de msi-ec que le widget a le droit d'écrire, avec leurs valeurs permises.
// status.fan_modes / status.shift_modes : listes séparées par des espaces (available_*).
function validAction(attr, value, status) {
  var st = status || {}
  var v = String(value === undefined || value === null ? "" : value)
  if (attr === "cooler_boost") return v === "on" || v === "off"
  var list = attr === "fan_mode" ? st.fan_modes : attr === "shift_mode" ? st.shift_modes : null
  if (list === null || list === undefined) return false
  return v !== "" && String(list).trim().split(/\s+/).indexOf(v) !== -1
}

// Message affiché dans le panneau après une écriture ; "" si elle a réussi.
function writeError(exitCode, stderr) {
  if (Number(exitCode) === 0) return ""
  if (String(stderr || "").indexOf("Permission denied") !== -1)
    return "droits insuffisants : reconnectez-vous après l'installation du correctif 1"
  return "écriture impossible"
}

// Pic de tr/min : maximum de l'historique et du pic mémorisé, en ignorant les valeurs
// supérieures à 3 × la médiane de l'historique (lectures aberrantes du compte-tours).
// Plancher de 8000 tr/min pour la limite : ventilateur à l'arrêt (médiane 0), les
// vitesses réelles ne sont pas écartées.
function filterPeak(history, peak) {
  var vals = (history || []).map(function(s) { return Number(s.cpuRpm) }).filter(function(n) { return isFinite(n) })
  var p = Number(peak)
  if (!isFinite(p)) p = 0
  if (vals.length === 0) return Math.round(p)
  var sorted = vals.slice().sort(function(a, b) { return a - b })
  var mid = sorted.length >> 1
  var median = sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
  var limit = Math.max(3 * median, 8000)
  var best = 0
  vals.concat([p]).forEach(function(n) { if (n <= limit && n > best) best = n })
  return Math.round(best)
}

// Adresse du premier GPU NVIDIA (vendor 0x10de, classe 0x03xxxx : affichage) parmi des
// lignes « adresse vendor classe » (tableau ou texte) ; "" s'il n'y en a pas.
function findDgpu(entries) {
  var lines = Array.isArray(entries) ? entries : String(entries || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = String(lines[i]).trim().toLowerCase().split(/\s+/)
    if (f.length >= 3 && f[1] === "0x10de" && /^0x03[0-9a-f]{4}$/.test(f[2])) return f[0]
  }
  return ""
}
