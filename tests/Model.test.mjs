// node --test tests/ — charge Model.js (fonctions globales, comme dans Quickshell).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const M = {}
vm.createContext(M)
vm.runInContext(readFileSync(new URL('../Model.js', import.meta.url), 'utf8'), M)
// Les tableaux créés dans le contexte vm ont un autre prototype : on compare des copies.
const plain = (v) => JSON.parse(JSON.stringify(v))
const cpuUsine = { temps: [52, 60, 65, 70, 82, 88], speeds: [0, 45, 50, 60, 65, 70, 75] }

test('parseCurve lit la courbe CPU d’usine', () => {
  assert.deepEqual(plain(M.parseCurve('0 52 45 60 50 65 60 70 65 82 70 88 75\n')), cpuUsine)
})
test('parseCurve rejette un texte vide ou incomplet', () => {
  assert.equal(M.parseCurve(''), null)
  assert.equal(M.parseCurve('1 2 3'), null)
})
test('speedAt suit les paliers de montée', () => {
  assert.equal(M.speedAt(cpuUsine, 40), 0)
  assert.equal(M.speedAt(cpuUsine, 52), 45)
  assert.equal(M.speedAt(cpuUsine, 64), 50)
  assert.equal(M.speedAt(cpuUsine, 95), 75)
})
test('pushSample garde les 300 derniers sans modifier l’original', () => {
  const h = Array.from({ length: 300 }, (_, i) => ({ t: i }))
  const n = M.pushSample(h, { t: 300 }, 300)
  assert.equal(n.length, 300)
  assert.equal(n[0].t, 1)
  assert.equal(n[299].t, 300)
  assert.equal(h.length, 300)
  assert.equal(h[0].t, 0)
})
test('spinDuration', () => {
  assert.equal(M.spinDuration(0), 0)
  assert.equal(M.spinDuration(2880), 1042)
  assert.equal(M.spinDuration(100), 4000)
  assert.equal(M.spinDuration(20000), 400)
})
test('gpuState', () => {
  assert.equal(M.gpuState('0', 'suspended'), 'veille')
  assert.equal(M.gpuState('51', 'active'), 'actif')
  assert.equal(M.gpuState('0', 'active'), 'veille')
})
test('formatRpm', () => {
  assert.equal(M.formatRpm(2880), '2 880 tr/min')
  assert.equal(M.formatRpm(0), 'arrêté')
  assert.equal(M.formatRpm(NaN), '—')
})
test('usbLabel', () => {
  assert.equal(M.usbLabel('on\n'), 'activée')
  assert.equal(M.usbLabel('off'), 'désactivée')
  assert.equal(M.usbLabel(''), null)
})
test('features : pilote d’origine', () => {
  assert.deepEqual(plain(M.features({ fan1: '', fan3: '', cpuCurve: '', cpuHyst: '', usb: '' })),
    { rpm: false, aux: false, curve: false, hyst: false, usb: false })
})
test('features : pilote gs76, ventilateur auxiliaire à l’arrêt', () => {
  const f = M.features({ hwmon: '/sys/class/hwmon/hwmon9', fan1: '2891\n', fan3: '0\n', cpuCurve: '0 52 45 60 50 65 60 70 65 82 70 88 75\n',
    cpuHyst: '7 3 3 3 3 3\n', usb: 'on\n' })
  assert.deepEqual(plain(f), { rpm: true, aux: true, curve: true, hyst: true, usb: true })
})
test('parseHysteresis et downThresholds (profil Default YAMDCC GS76)', () => {
  assert.deepEqual(plain(M.parseHysteresis('7 3 3 3 3 3\n')), [7, 3, 3, 3, 3, 3])
  assert.equal(M.parseHysteresis('7 3'), null)
  assert.deepEqual(plain(M.downThresholds(cpuUsine, [7, 3, 3, 3, 3, 3])), [45, 57, 62, 67, 79, 85])
})
test('rpmScale', () => {
  assert.equal(M.rpmScale(0, []), 6000)
  assert.equal(M.rpmScale(6500, [{ cpuRpm: 2891 }]), 6500)
  assert.equal(M.rpmScale(0, [{ cpuRpm: 7100 }]), 7100)
})
test('tooltip', () => {
  assert.equal(M.tooltip(64, 2880), 'CPU 64 °C · 2 880 tr/min')
})

// Une lecture ratée (fichier vide ou disparu, -ENODATA, -EIO) ne doit pas passer pour une mesure.
test('num : texte vide ou invalide → NaN', () => {
  assert.equal(M.num('64\n'), 64)
  assert.ok(Number.isNaN(M.num('')))
  assert.ok(Number.isNaN(M.num('abc')))
})
test('formatTemp : « — » si la lecture a échoué', () => {
  assert.equal(M.formatTemp(58), '58 °C')
  assert.equal(M.formatTemp(NaN), '—')
})
test('formatRpm : lecture ratée → « — », pas « arrêté »', () => {
  assert.equal(M.formatRpm(M.num('')), '—')
})
test('validSample : échantillon avec lecture ratée ignoré', () => {
  assert.equal(M.validSample({ t: 1, cpuTemp: 60, cpuRpm: 2891 }), true)
  assert.equal(M.validSample({ t: 1, cpuTemp: NaN, cpuRpm: 2891 }), false)
  assert.equal(M.validSample({ t: 1, cpuTemp: 60, cpuRpm: NaN }), false)
})
test('features : rpm dépend de la présence du hwmon, pas d’une lecture réussie', () => {
  const f = M.features({ hwmon: '/sys/class/hwmon/hwmon9', fan1: '', fan3: '', cpuCurve: '', cpuHyst: '', usb: '' })
  assert.equal(f.rpm, true)
  assert.equal(M.features({ hwmon: '', fan1: '', fan3: '', cpuCurve: '', cpuHyst: '', usb: '' }).rpm, false)
})
test('gpuState : température illisible et GPU actif → « inconnu »', () => {
  assert.equal(M.gpuState('', 'active'), 'inconnu')
  assert.equal(M.gpuState('', 'suspended'), 'veille')
})

test('validAction : seules les valeurs annoncées par le pilote sont acceptées', () => {
  const st = { fan_modes: 'auto silent advanced', shift_modes: 'eco comfort turbo' }
  assert.equal(M.validAction('fan_mode', 'silent', st), true)
  assert.equal(M.validAction('fan_mode', 'turbo', st), false)
  assert.equal(M.validAction('shift_mode', 'turbo', st), true)
  assert.equal(M.validAction('shift_mode', 'auto', st), false)
  assert.equal(M.validAction('cooler_boost', 'on', st), true)
  assert.equal(M.validAction('cooler_boost', 'off', st), true)
  assert.equal(M.validAction('cooler_boost', '1', st), false)
  assert.equal(M.validAction('rm', 'x', {}), false)
  assert.equal(M.validAction('fan_mode', 'silent', {}), false)
  assert.equal(M.validAction('fan_mode', 'silent; reboot', { fan_modes: 'auto silent' }), false)
})
test('writeError', () => {
  assert.equal(M.writeError(0, ''), '')
  assert.ok(M.writeError(1, 'sh: /sys/devices/platform/msi-ec/fan_mode: Permission denied').includes('reconnectez-vous'))
  assert.equal(M.writeError(1, 'sh: Invalid argument'), 'écriture impossible')
})
test('filterPeak ignore les lectures aberrantes du compte-tours', () => {
  const h = [{ cpuRpm: 2800 }, { cpuRpm: 2900 }, { cpuRpm: 2850 }, { cpuRpm: 68571 }]
  assert.equal(M.filterPeak(h, 68571), 2900)
  assert.equal(M.filterPeak(h, 3100), 3100)
  assert.equal(M.filterPeak([], 4200), 4200)
  assert.equal(M.filterPeak([], 0), 0)
})
test('rpmScale n’est pas gonflée par une lecture aberrante', () => {
  const h = [{ cpuRpm: 2800 }, { cpuRpm: 2900 }, { cpuRpm: 2850 }, { cpuRpm: 68571 }]
  assert.equal(M.rpmScale(68571, h), 6000)
})
test('findDgpu', () => {
  assert.equal(M.findDgpu(['0000:00:02.0 0x8086 0x030000', '0000:02:00.0 0x10de 0x030200']), '0000:02:00.0')
  assert.equal(M.findDgpu(['0000:00:02.0 0x8086 0x030000']), '')
  assert.equal(M.findDgpu(['0000:02:00.1 0x10de 0x040300']), '')
  assert.equal(M.findDgpu([]), '')
  assert.equal(M.findDgpu('0000:02:00.0 0x10DE 0x030000\n'), '0000:02:00.0')
})
test('gpuState : pas de GPU dédié → « absent », jamais « veille »', () => {
  assert.equal(M.gpuState('', '', ''), 'absent')
  assert.equal(M.gpuState('0', '', ''), 'absent')
  assert.equal(M.gpuState('0', 'suspended', '0000:02:00.0'), 'veille')
})
