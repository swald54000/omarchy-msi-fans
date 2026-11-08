// node --test tests/ — aucune trace personnelle ne doit rester dans les fichiers versionnés.
// Les motifs sont découpés ("a" + "b") pour que ce fichier ne se signale pas lui-même.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const racine = new URL('..', import.meta.url).pathname

const MOTIFS_FIXES = ['/ho' + 'me/', 'Wo' + 'rk/', 'BA' + 'T1', '0000:01:00' + '.0',
  'game' + 'mode', 'su' + 'do', 'msi-fan-' + 'control']
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/
const NOM = 'sw' + 'ald'
const JETONS_PUBLICS = [NOM + '.fans', NOM + '54000']

// Retourne la liste des problèmes d'un texte (un par ligne fautive).
function traces(texte) {
  const trouvees = []
  texte.split('\n').forEach((ligne, i) => {
    for (const m of MOTIFS_FIXES) if (ligne.includes(m)) trouvees.push(`${i + 1}: « ${m} »`)
    if (EMAIL.test(ligne)) trouvees.push(`${i + 1}: adresse e-mail`)
    let reste = ligne.toLowerCase()
    for (const j of JETONS_PUBLICS) reste = reste.split(j).join('')
    if (reste.includes(NOM)) trouvees.push(`${i + 1}: « ${NOM} » hors jetons publics`)
  })
  return trouvees
}

test('le détecteur reconnaît chaque motif planté', () => {
  const plante = ['cd /ho' + 'me/x', 'Wo' + 'rk/p', 'BA' + 'T1', '0000:01:00' + '.0', 'game' + 'mode',
    'su' + 'do ls', 'msi-fan-' + 'control', 'a' + '@exemple.org', 'by ' + NOM]
  for (const l of plante) assert.ok(traces(l).length > 0, l)
  assert.deepEqual(traces(`${NOM}.fans et ${NOM}54000 sont publics`), [])
})

test('aucun fichier versionné ne contient de trace personnelle', () => {
  const fichiers = execFileSync('git', ['ls-files', '-z'], { cwd: racine }).toString().split('\0').filter(Boolean)
  const fautes = []
  for (const f of fichiers) {
    const brut = readFileSync(new URL('../' + f, import.meta.url))
    if (brut.includes(0)) continue // binaire (image)
    for (const t of traces(brut.toString('utf8'))) fautes.push(`${f}:${t}`)
  }
  assert.deepEqual(fautes, [])
})
