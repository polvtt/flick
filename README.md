# Flick

Gestionnaire de fenêtres par gestes trackpad pour macOS. Agent de barre de menus
léger (`LSUIElement`), sans fenêtre, écrit en Swift natif sans dépendance.

Place le curseur sur la **barre de titre** d'une fenêtre (ou n'importe où en
tenant **Ctrl**) et fais un **swipe à deux doigts** : une prévisualisation animée
montre la zone cible, et la fenêtre s'y ancre au relâchement.

## Gestes

| Geste (swipe 2 doigts) | Action |
|---|---|
| ← gauche | moitié gauche |
| → droite | moitié droite |
| ↑ haut | maximiser |
| ↓ bas | recentrer |
| ↖ ↗ ↙ ↘ diagonale | quart d'écran correspondant |

Un retour haptique confirme l'ancrage. Les swipes ailleurs que sur la barre de
titre passent normalement : le scroll du contenu n'est pas gêné.

## Prérequis

- macOS 12+
- Xcode Command Line Tools (`xcode-select --install`) pour `swiftc`

## Build

```bash
./setup_signing.sh    # une seule fois : crée une identité de signature locale stable
./build.sh            # compile + empaquette build/Flick.app
```

La signature avec identité stable permet à l'autorisation d'Accessibilité de
**survivre aux recompilations** (sinon macOS l'oublie à chaque build).

## Première utilisation

```bash
open build/Flick.app
```

1. macOS ouvre **Réglages Système → Confidentialité et sécurité → Accessibilité**.
2. Active **Flick** dans la liste.
3. Relance l'app. L'icône `⌾` apparaît dans la barre de menus (« Flick — actif »).

L'accès Accessibilité est nécessaire pour lire et déplacer les fenêtres des autres
apps. **Aucune donnée ne quitte la machine.**

> Lance toujours l'app via `open build/Flick.app`, jamais le binaire interne
> depuis un terminal : macOS attribuerait alors l'autorisation au terminal.

## Lancer au démarrage

Réglages Système → Général → Ouverture → **＋** → `Flick.app`.

## Réglages

En haut de [`Sources/main.swift`](Sources/main.swift), bloc `Config` :

- `titleBarBand` — hauteur de la zone sensible (défaut 34 pt)
- `minTravel` — amplitude minimale d'un geste (défaut 20 pt)
- `diagonalRatio` — seuil pour déclencher un coin plutôt qu'une moitié
- `invertX` / `invertY` — inverser si une direction part à l'envers
- `captureAnywhere` — déclencher partout sur la fenêtre (intercepte le scroll)
- `gap` — marge autour des fenêtres ancrées (0 = collé aux bords)

Après modification : `./build.sh`, puis relancer l'app.

## Architecture

- **Capture** : un `CGEventTap` sur les événements de scroll, filtré au trackpad
  (`scrollWheelEventIsContinuous`).
- **Reconnaissance** : accumulation des deltas pendant le geste, axe dominant +
  seuil de diagonale pour choisir la zone.
- **Ciblage** : `AXUIElementCopyElementAtPosition` au curseur, puis
  redimensionnement via l'API Accessibilité.
- **Aperçu** : une fenêtre overlay translucide animée via `NSAnimationContext`.

## Limites connues

- Certaines fenêtres non natives (Electron/Java) exposent mal leur taille via l'API
  Accessibilité et peuvent résister au redimensionnement.
- Déplacement entre écrans/Spaces et tiling natif non implémentés : socle
  extensible.

## Licence

Usage personnel. Code original.
