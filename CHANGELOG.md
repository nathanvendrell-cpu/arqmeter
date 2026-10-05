# Changements

## 1.0.13 — 2026-10-06

- Source facultative Claude Desktop déjà connecté, sans seconde connexion :
  lecture passive du panneau Utilisation, session/semaine et resets distincts.
- Autorisation Accessibilité propre à Arqmeter requise. Le panneau doit rester
  ouvert ; pas de navigation automatique ni garantie de fraîcheur serveur.
- Lectures toutes les 60 s, travail AX hors UI, refus des parcours incomplets,
  unités établies et booléens rejetés. Aucune lecture de secrets ni appel modèle.
- Correction d'un arrondi machine fraction → pourcentage ; les vrais décimaux
  conservent leur valeur et leur pourcentage restant conservateur.
- 35 tests ciblés et 7 autotests réussis. L'échec initial d'arrondi est conservé.
- Production installée mais acquisition native non validée : droit macOS manquant.
  Aucun pourcentage acquis par un autre outil n'a été injecté dans les données.
- HUD, conseils, Codex, préférences, historiques et rollback conservés.

## 1.0.12 — 2026-10-05

- Réglages communs : plusieurs sources sélectionnables, ordre mémorisé, flèches
  et actions accessibles ; cartes de l’onglet Quota dans cet ordre.
- Fenêtres Claude session/semaine indépendantes ; la barre affiche la fenêtre
  connue la plus contraignante, sans addition de quotas ni compteur de contexte.
- Connexion facultative via la page officielle dans WebKit ; lecture bornée
  et cache privé, états absents/périmés honnêtes, aucun appel modèle.
  Parcours authentifié et rafraîchissements réels encore à valider.
- Conseil ratio entrée/sortie descriptif, avec cache et limite explicites :
  il ne démontre pas un gaspillage, un coût ou un quota consommé.
- Comparaison de l’entrée par réponse au lieu des totaux de sessions de longueurs
  différentes ; modèles/providers/workspaces inconnus ou mixtes non comparés.
- Pas de réduction, suppression ou changement de modèle automatique.
- Présentation, interactions du HUD, SQLite, historiques et essais conservés.
- 111 tests moteur du candidat de connexion ; 9 tests ciblés des conseils après
  correction (5 nouveaux), 7 autotests et 18 contrôles de DOM construits réussis.
- Premier glisser-déposer natif négatif conservé ; ordre par flèches et
  persistance recettés en QA, sans prétendre à une acceptation visuelle installée.
- Le candidat Token Value reste exclu.

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
