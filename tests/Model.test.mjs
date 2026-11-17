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
test('features : aucun capteur de tr/min', () => {
  assert.deepEqual(plain(M.features({ fan1: '', fan3: '' })), { rpm: false, aux: false })
})
test('features : capteur présent, ventilateur auxiliaire à l’arrêt', () => {
  const f = M.features({ hwmon: '/sys/class/hwmon/hwmon9', fan1: '2891\n', fan3: '0\n' })
  assert.deepEqual(plain(f), { rpm: true, aux: true })
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
  const f = M.features({ hwmon: '/sys/class/hwmon/hwmon9', fan1: '', fan3: '' })
  assert.equal(f.rpm, true)
  assert.equal(M.features({ hwmon: '', fan1: '', fan3: '' }).rpm, false)
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
  assert.ok(M.writeError(1, 'sh: 1: cannot create /sys/x: Permission non accordée').includes('reconnectez-vous'))
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

// Les listes de modes ne changent pas toutes seules : chaque relecture coûte ~1,4 ms par
// registre de l'EC. Elles ne sont relues qu'au besoin, pas à chaque échantillon.
test('staticDue : jamais relu en continu quand le panneau est fermé et les listes connues', () => {
  for (let tick = 1; tick <= 50; ++tick) assert.equal(M.staticDue(tick, false, true), false)
})

test('staticDue : panneau ouvert → une relecture tous les 5 échantillons', () => {
  const dus = []
  for (let tick = 1; tick <= 20; ++tick) if (M.staticDue(tick, true, true)) dus.push(tick)
  assert.deepEqual(dus, [5, 10, 15, 20])
})

test('staticDue : listes encore inconnues (pilote chargé après le widget) → nouvel essai tous les 5 échantillons', () => {
  const dus = []
  for (let tick = 1; tick <= 12; ++tick) if (M.staticDue(tick, false, false)) dus.push(tick)
  assert.deepEqual(dus, [5, 10])
})

test('Panel.qml : sample() ne relit que les fichiers qui changent', () => {
  const qml = readFileSync(new URL('../Panel.qml', import.meta.url), 'utf8')
  const debut = qml.indexOf('function sample()')
  const corps = qml.slice(debut, qml.indexOf('files.forEach', debut))
  for (const fixe of ['fanModesFile', 'shiftModesFile'])
    assert.ok(!corps.includes(fixe), fixe + ' ne doit pas être relu à chaque échantillon')
  for (const vivant of ['cpuTempFile', 'cpuSpeedFile', 'fanModeFile', 'shiftModeFile', 'boostFile', 'fan1File'])
    assert.ok(corps.includes(vivant), vivant + ' doit rester échantillonné')
})

// Une animation continue dans la barre redessine l'écran en permanence : mesuré sur batterie,
// 28 % d'un cœur pour la barre, 19 % pour le compositeur et 5 à 7 W, ni PSR ni DRRS possibles.
test('Panel.qml : aucune animation ne tourne panneau fermé', () => {
  const qml = readFileSync(new URL('../Panel.qml', import.meta.url), 'utf8')
  const debut = qml.indexOf('BarIconButton {')
  const bouton = qml.slice(debut, qml.indexOf('\n  }\n', debut))
  assert.ok(!/Animator|Animation\s*\{|Behavior/.test(bouton), 'le bouton de la barre ne doit rien animer')
  const lignes = qml.split('\n')
  lignes.forEach((ligne, i) => {
    if (/RotationAnimator|NumberAnimation|SequentialAnimation/.test(ligne)) {
      const running = lignes.slice(i, i + 4).find((l) => /^\s*running:/.test(l)) || ''
      assert.ok(running.includes('root.opened'), 'animation ligne ' + (i + 1) + ' : doit dépendre de root.opened')
    }
    if (/^\s*iconSpinning:/.test(ligne))
      assert.ok(ligne.includes('root.opened'), 'iconSpinning ligne ' + (i + 1) + ' : doit dépendre de root.opened')
  })
})

test('Panel.qml : dans le panneau ouvert, l’icône tourne à la vitesse du ventilateur', () => {
  const qml = readFileSync(new URL('../Panel.qml', import.meta.url), 'utf8')
  const debut = qml.indexOf('id: heroIcon')
  const hero = qml.slice(debut, qml.indexOf('onRunningChanged', debut))
  assert.match(hero, /running: root\.opened && \(root\.boosting \|\| root\.spinMs > 0\) && !Style\.reduceMotion/)
  assert.match(hero, /duration: root\.spinMs > 0 \? root\.spinMs : 900/)
})
