# Reprise : quota Claude automatique

## Objectif

Lire les limites officielles Claude **session (5 h) et semaine (7 j)** en
arrière-plan, sans demander d'ouvrir Utilisation, sans appel de modèle et sans
changer silencieusement de compte. Un volume de tokens, une fenêtre de contexte
ou un coût n'est pas un quota d'abonnement.

## Point de départ : 1.0.13

Mise à jour documentaire du code 1.0.13 : **aucun correctif quota, nouveau binaire
ou nouvelle release**.

Le lecteur AX passif vise la fenêtre principale et dépend d'Utilisation ouvert.
Acquisition réelle observée après autorisation, puis régression après relance de
Claude malgré un droit valide. Aucun défaut de sélection/parsing n'est établi.

Sonde isolée Electron `AXManualAccessibility` : setter accepté, relecture fausse,
**aucune exposition effective ni récupération prouvée**. Non intégrée au produit ;
ne pas répéter le setter, activer VoiceOver ou piloter périodiquement la fenêtre.

## Points d'entrée

| Rôle | Fichiers |
|---|---|
| Lecteur natif et timer | `Sources/Arqmeter/ClaudeDesktopQuotaReader.swift` |
| Modèle natif, unités et fraîcheur | `Sources/ArqmeterCore/ClaudeDesktopQuota.swift` |
| Payload officiel Claude Code | `Sources/ArqmeterCore/ClaudeQuota.swift`, `Resources/claude-statusline-fragment.sh`, branche `--capture-claude-status` de `Sources/Arqmeter/main.swift` |
| Page officielle et extraction | `Sources/Arqmeter/ClaudeOfficialPage.swift`, `Resources/claude-official-usage.js`, `Sources/ArqmeterCore/ClaudeWebQuota.swift` |
| Choix explicite de source et présentation | `ClaudePlanQuotaReadout` dans `ClaudeWebQuota.swift`, `ProviderQuotaMenu.swift`, `ProviderQuotaCards.swift` |
| Tests existants | `Tests/ArqmeterCoreTests/ClaudeDesktopQuotaTests.swift`, `ClaudeQuotaTests.swift`, `ClaudeWebQuotaTests.swift`, `scripts/test-claude-official-usage.mjs` |

Les chemins de présentation sont sous `Sources/Arqmeter/`. Conserver Codex,
historiques, préférences, sélection des sources, déduplication et rollback.

## Source à qualifier avant de coder

- Qualifier une source **officielle et documentée** sans panneau ouvert.
  Le pont status line reçoit `rate_limits` selon les événements Claude Code :
  ce n'est pas un poller autonome.
  [Référence officielle](https://code.claude.com/docs/en/statusline).
- Qualifier l'authentification avec `claude auth status --json`, sans extraire
  ses credentials. Claude Code, Desktop et WebKit peuvent avoir des comptes
  différents : vérifier la cohérence et choisir explicitement la source.
- WebKit possède sa propre session. Pas d'import de cookies/tokens, endpoint
  privé, trousseau, base privée ou `--print` pour obtenir un quota : cela peut
  déclencher une requête modèle.
- Si aucune source conforme n'existe, documenter la limite et le choix nécessaire,
  sans promettre l'autonomie ni fabriquer de relevé.

## Contrat et recette

Conserver fenêtres indépendantes, unités/bornes, TTL de trois minutes et refus
des lectures partielles. Absence, péremption ou erreur → indisponible, jamais
100 % ni fallback silencieux. Réception/lecture locale ≠ nouvelle mesure serveur ;
réémettre un ancien payload ne prouve pas sa fraîcheur.

Tester absence, erreurs, données partielles, reset, unités et choix exclusif.
Recetter **le service GUI installé** : deux observations automatiques espacées,
Utilisation **fermé**, session/semaine/reset et provenance explicables, reprise
après relance normale de Claude, compte cohérent, CPU/RAM et délais bornés.
Aucun appel modèle ni dépense de quota. Tests synthétiques et sonde CLI ne
remplacent pas cette preuve. Revue avant déploiement, rollback conservé.
