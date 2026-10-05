# Changements

## 1.0.10 — 2026-10-05

- Un cadre de barre de menus commun : logo Claude + quota restant, logo
  OpenAI/Codex + quota restant. Les deux limites restent distinctes.
- Quota Claude issu uniquement des champs officiels de la status line locale,
  avec état absent/périmé honnête et aucune interrogation d’un modèle.
- Fragment de liaison facultatif, compatible avec une status line existante,
  sans modification automatique des réglages utilisateur ; guard de rollback.
- Rafraîchissement du petit cache local toutes les deux secondes, sans modifier
  la cadence d’interrogation officielle Codex.
- Aucun changement du HUD, de ses interactions ou des historiques.
- 92 tests moteur et six autotests conservés ; contrôle du dessin hors écran
  distinct d’une observation native de la barre de menus.
- Le candidat Token Value 1.0.9 n’est pas inclus.

## 1.0.8 — 2026-10-05

- Verre clair avec titres, chiffres, unités et graduations foncés ; aiguilles
  sombres et relief conservé, sans modification des calculs.
- Fond plus couvrant quand la fenêtre est active, plus transparent hors focus,
  sans fermeture automatique, polling global ni animation permanente.
- Hors focus, retrait du flou blanc sur le fond ET les cartes : le changement
  n'est plus limité à une seule couche. Les textes et cadrans restent opaques.
- Déplacement par l’en-tête ; masquage/réouverture par le compteur du menu bar,
  à la même position pendant la même exécution.
- Fond opaque clair pour l’accessibilité ; apparence indépendante du mode sombre.
- Moteur multi-source, quota Codex, SQLite, déduplication, historiques, preuves
  et essais préservés.
- Publication initiale d’un instantané nettoyé : exemples de projets génériques,
  aucun ancien historique Git interne ni données utilisateur.
