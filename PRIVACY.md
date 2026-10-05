# Données et publication

## Sur votre Mac

Arqmeter lit les journaux et métadonnées locaux des outils détectés, ainsi que
les limites/données quotidiennes Codex lorsqu’elles sont accessibles par son
outil officiel. Cette lecture peut utiliser la connexion déjà configurée de
Codex ; elle n’exécute pas un modèle pour produire les statistiques.

Les événements d’usage normalisés, leurs timestamps, workspace/projet, modèle
et provenance restent dans les historiques locaux. Les prompts et réponses
ne sont pas stockés dans la base d’événements normalisés. Les suggestions et
essais restent des analyses locales ; aucune économie non mesurée n’est promise.

La liaison Claude optionnelle reçoit le JSON officiel de la status line, puis
ne conserve que les pourcentages d’usage, resets, heure de réception et version
CLI assainie dans `claude-quota.json` (permissions 0600). Les champs de contexte,
prompts, transcripts, workspace, session et identité du compte sont ignorés.
Aucune requête modèle ou réseau n’est lancée par cette liaison. Elle ne remplace
pas votre status line et n’exploite pas les anciens caches d’autres applications.

Un second mode, choisi explicitement par « Connecter Claude », utilise un
navigateur WebKit dédié à la page officielle d’utilisation de claude.ai.
L’utilisateur y effectue sa connexion. WebKit gère lui-même sa session persistante ;
Arqmeter n’accède pas aux API de cookies, credentials ou codes de vérification,
et n’importe pas la session de Chrome ou de Claude Desktop.

Le lecteur JavaScript est borné aux cartes de quota de cette page, pas aux
conversations, formulaires, stockage web ou identité du compte. Le fichier local
claude-official-page-quota.json (0600) contient au plus les deux pourcentages,
libellés/resets réellement fournis et heures de chargement/lecture. Aucun token
d’authentification n’y est enregistré. Après une lecture réussie, ce mode recharge
la page officielle toutes les 60 secondes, avec délai croissant en cas d’erreur ;
il s’agit de requêtes réseau normales du navigateur, pas de requêtes modèle.
Le suivi est facultatif et arrêtable sans effacer l’historique utilisateur.
La page ne fournit pas un timestamp de mesure serveur.

Les logos vectoriels identifient Claude et OpenAI/Codex, sans endorsement.
Leurs tracés proviennent des favicons officiels ; ils ne deviennent pas la marque
d’Arqmeter et ne signifient pas une affiliation à Anthropic ou OpenAI.

## Dans ce dépôt

La publication est un instantané des sources nécessaires, des tests construits,
de la configuration de build et de la documentation publique. Elle n’inclut
pas les historiques personnels, bases SQLite, authentifications, réglages du
Mac, journaux d’exécution, backups, anciens commits internes ni captures du bureau.
La release contient uniquement le bundle d’application et ses sommes de contrôle.

Un contrôle par liste de fichiers autorisés et recherche de motifs de credentials,
emails privés et chemins de machine a été exécuté avant publication. Ce contrôle
ne constitue pas un audit de sécurité exhaustif de l’application.
