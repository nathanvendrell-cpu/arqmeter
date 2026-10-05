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

## Dans ce dépôt

La publication est un instantané des sources nécessaires, des tests construits,
de la configuration de build et de la documentation publique. Elle n’inclut
pas les historiques personnels, bases SQLite, authentifications, réglages du
Mac, journaux d’exécution, backups, anciens commits internes ni captures du bureau.
La release contient uniquement le bundle d’application et ses sommes de contrôle.

Un contrôle par liste de fichiers autorisés et recherche de motifs de credentials,
emails privés et chemins de machine a été exécuté avant publication. Ce contrôle
ne constitue pas un audit de sécurité exhaustif de l’application.
