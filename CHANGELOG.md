# Changements

## Pont Claude 0.1.1 — 2026-10-07 — sources

- Correction d'un filtre de réception : `changed` indique quelles valeurs ont
  changé, pas quelles mesures sont présentes. Les quotas fournis dans un relevé
  après tour ne sont plus ignorés lorsque seul contexte/coût a changé.
- Relevés identiques regroupés pendant 60 s, au lieu d'une déduplication sans
  expiration. Chiffres différents transmis immédiatement ; renouvellement
  uniquement sur un nouvel événement réel, jamais sur une simple horloge.
- Trois tests supplémentaires : quota identique après intervalle, absence de
  renouvellement sans événement, changement immédiat et session épuisée non
  remplacée par la fenêtre hebdomadaire.
- Binaire 1.0.20, UI, bases et préférences inchangés. Rechargement du mod requis
  pour les sessions Claude Code déjà ouvertes ; pas de réponse IA déclenchée.

## 1.0.20 — 2026-10-07 — sources

- La vue complète ouvre l'analyse quotidienne : semaine civile ou mois,
  navigation dans les périodes, barres interactives et valeurs exactes par jour.
- Volumes officiels Codex du compte en UTC séparés des événements locaux ;
  choix de source, mesure et dossier réellement observé. Durée locale pour Ollama.
- Jours manquants, événements sans mesure et journée en cours explicités ;
  aucun zéro, quota, coût ou token local fabriqué. Cache non additionné deux fois.
- Cadrans en direct et comparaisons déplacés dans des volets secondaires de la
  vue complète. HUD validé, sessions, conseils, preuves et essais conservés.
- Lecture ciblée du SQLite existant, pas de nouvelle collecte, dépendance tierce
  ou appel modèle. Huit tests moteur supplémentaires et recette des filtres/races.
- Stabilisation Claude de 1.0.19 conservée ; pas de changement des bases,
  de la déduplication ou des préférences utilisateur.

## 1.0.19 — 2026-10-07 — sources

- Pont Claude Code Mods passif : fenêtres officielles 5 h et semaine, sans
  réponse modèle, réseau supplémentaire, lecture de credentials ou transcripts.
- Choix mémorisé 5 h / Semaine / Les deux ; 5 h en premier, quotas restants séparés.
- Correction de la disparition après trois minutes sans événement : dernier
  relevé conservé avec horloge, infobulle et état non actualisé explicites. Aucun
  timestamp renouvelé ; chaque fenêtre est invalidée à son reset connu.
- L'ellipse ne signifie une lecture en cours que lorsqu'une lecture est active.
- Lecture de secours officielle bornée, rejet strict des réponses nulles, backoff
  conservé et nettoyage des enfants. Les anciens parcours Web/Desktop restent
  archivés dans le code mais ne sont plus proposés comme suivi courant.
- Correctifs cache-aware des conseils conservés : pas de gain/coût déduit du
  volume cache, couverture des mesures et essais manuels toujours accessibles.
- HUD validé, Codex, adaptateurs, historiques SQLite et préférences préservés.
- Publication des sources uniquement : les sommes de contrôle de la distribution
  précédente restent identifiées comme telles, sans les attribuer à ce build.

## 1.0.14 — 2026-10-06 — sources

- Conseils cache-aware : contexte traité, cache lu et entrée hors cache distincts.
- Absence de promesse d'économie sur une hausse dominée par le cache ; données
  partielles et modèles mélangés non transformés en comparaison fiable.
- Synchronisation du connecteur officiel avec la baseline installée.

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
- À l'installation initiale, acquisition bloquée par le droit macOS manquant.
  Après autorisation, lectures natives réelles observées, puis régression après
  relance de Claude malgré un droit valide. Aucun correctif livré, aucune autonomie
  panneau fermé validée, aucune injection de quota d'un autre outil.
- Documentation de reprise actualisée : [suivi automatique Claude](HANDOFF_CLAUDE_QUOTA.md).
  Ce suivi documentaire ne modifie ni le binaire, ni le tag, ni la release 1.0.13.
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
